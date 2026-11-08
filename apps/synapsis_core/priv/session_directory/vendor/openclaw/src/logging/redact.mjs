import { isSensitiveUrlQueryParamName } from "../../packages/net-policy/src/redact-sensitive-url.mjs";
import { redactStructuredAuthHeaders } from "../../packages/acp-core/src/structured-auth-redaction.mjs";
import { compileConfigRegex } from "../security/config-regex.mjs";
import { readInvocationLoggingConfig as readLoggingConfig } from "../../../../host-history-services.mjs";
import { replacePatternBounded } from "./redact-bounded.mjs";
import { LINEAR_MATCHER_SOURCES } from "./redact-linear-matchers.mjs";
import { maskToken } from "./redact-mask.mjs";
import { maskSecretValue } from "./redact-mask.mjs";
import { splitSecretValueForMask } from "./redact-mask.mjs";
import { splitFormAwareCredentialValue } from "./redact-mask.mjs";
import { getSecretCaptureStart } from "./redact-pattern-runtime.mjs";
import { selectSecretCapture } from "./redact-pattern-runtime.mjs";
import { parseRedactPatternSource } from "./redact-pattern-runtime.mjs";
import { readRedactMatch } from "./redact-pattern-runtime.mjs";
import { redactPemBlock } from "./redact-pattern-runtime.mjs";
import { replaceRedactPattern } from "./redact-pattern-runtime.mjs";
import { rewriteOpenEndedRepeats } from "./redact-pattern-runtime.mjs";
import { setRedactPatternPrefilter } from "./redact-pattern-runtime.mjs";
import { AWS_SECRET_ACCESS_KEY_MATCHER } from "./redact-patterns.mjs";
import { createBackendRedactPatterns } from "./redact-patterns.mjs";
import { DEFAULT_REDACT_PATTERNS } from "./redact-patterns.mjs";
import { FORM_BODY_KEY_INVISIBLE_CHARS } from "./redact-patterns.mjs";
import { IDENTIFIER_SAFE_TOKEN_BOUNDARY } from "./redact-patterns.mjs";
import { VENDOR_TOKEN_REDACT_PATTERNS } from "./redact-patterns.mjs";
import { PEM_REDACT_MATCHER } from "./redact-pem.mjs";
import { PEM_REDACT_PATTERN_SOURCE } from "./redact-pem.mjs";
import { startRedactionMeasurement } from "./redact-performance.mjs";
import { couldMatchDefaultRedactPatterns } from "./redact-prefilter.mjs";
import { couldMatchVendorRedactPatterns } from "./redact-prefilter.mjs";
import { redactRegisteredSecretValues } from "./secret-redaction-registry.mjs";
const DEFAULT_REDACT_MODE                      = "tools";
const backendPatterns = createBackendRedactPatterns();
const shellReferencePreservingPatterns = new WeakSet                       ();
const builtInResolvedPatterns = new WeakSet                       ();
const vendorResolvedPatterns = new WeakMap                                      ();
const vendorSources = new Set(VENDOR_TOKEN_REDACT_PATTERNS);
const chunkUnsafePatterns = new WeakSet                       ();
const canonicalBuiltInSources = new Set        (
  DEFAULT_REDACT_PATTERNS.filter((entry)                  => typeof entry === "string"),
);
const formAwareEqualsAssignmentPatterns = new WeakSet                       ();
let defaultResolvedPatterns                                     ;
let warnedInvalidPatterns = false;
const FORM_BODY_KEY_OBFUSCATION_RE = new RegExp(
  String.raw`[${FORM_BODY_KEY_INVISIBLE_CHARS}+]`,
  "gu",
);
const FORM_BODY_KEY_SEPARATOR_RE = /[\p{C}\p{Z}\u115F\u1160\u3164\uFFA0+]/gu;
const FORM_BODY_PERCENT_ESCAPE_RE = /%[0-9A-Fa-f]{2}/u;
const FORM_BODY_KEY = String.raw`[${FORM_BODY_KEY_INVISIBLE_CHARS}+]*(?:[A-Za-z_]|%[0-9A-Fa-f]{2})(?:[A-Za-z0-9_.-]|%[0-9A-Fa-f]{2}|[${FORM_BODY_KEY_INVISIBLE_CHARS}+])*`;
const FORM_BODY_VALUE = "[^&\\s<>]*";
const URL_QUERY_VALUE = "[^&#\\s<>]*";
const FORM_BODY_PAIR = String.raw`${FORM_BODY_KEY}=${FORM_BODY_VALUE}`;
const FORM_BODY_RE = new RegExp(String.raw`^${FORM_BODY_PAIR}(?:&${FORM_BODY_PAIR})+$`, "u");
const FORM_BODY_SUBSTRING_RE = new RegExp(
  String.raw`(^|[\s:({\[,="'` + "`" + String.raw`])(${FORM_BODY_PAIR}(?:&${FORM_BODY_PAIR})+)`,
  "gu",
);
const ENCODED_FORM_PAIR_RE = new RegExp(
  String.raw`(^|[\s:({\[,="'` + "`" + String.raw`&])(${FORM_BODY_KEY})=(${FORM_BODY_VALUE})`,
  "gu",
);
const FORM_BODY_CONTEXT_SINGLE_PAIR_RE = new RegExp(
  String.raw`(\b(?:body|form(?:[-_\s]?body)?)\s*[:=]\s*(["'\x60]?))(${FORM_BODY_KEY})=(${FORM_BODY_VALUE})(["'\x60]?)`,
  "giu",
);
const URL_QUERY_PAIR_RE = new RegExp(
  String.raw`([?&])(${FORM_BODY_KEY})=(${URL_QUERY_VALUE})`,
  "gu",
);
const FORM_BODY_LINE_BREAK_SPLIT_RE = /(\r\n|\r|\n)/u;
const FORM_BODY_LINE_BREAK_SEGMENT_RE = /^(?:\r\n|\r|\n)$/u;
function parsePattern(raw               )                               {
  if (raw === PEM_REDACT_PATTERN_SOURCE) {
    return PEM_REDACT_MATCHER;
  }
  if (typeof raw !== "string" && !(raw instanceof RegExp)) {
    // Rejected config still reaches diagnostic redaction; only internal matchers have exec.
    return raw !== null && typeof raw === "object" && typeof raw.exec === "function" ? raw : null;
  }
  // Linear matchers and compiled regexes share the source's masking policies below.
  let pattern                               =
    typeof raw === "string" ? (LINEAR_MATCHER_SOURCES.get(raw) ?? null) : null;
  let canPrefilter = true;
  if (raw instanceof RegExp) {
    if (raw.flags.includes("g")) {
      pattern = raw;
    } else {
      pattern = new RegExp(raw.source, `${raw.flags}g`);
    }
  } else if (!pattern && raw.trim()) {
    const [source, flags] = parseRedactPatternSource(raw);
    // Open-ended repeats on canonical built-in flat single-character atoms compile without
    // one backtrack stack entry per repetition, so multi-megabyte values no longer overflow
    // the regex stack. Operator-configured sources compile unmodified: legacy escape and
    // class boundaries parse their atoms in ways the rewriter does not model, so rewriting
    // them could silently change the configured pattern's language.
    const optimized = canonicalBuiltInSources.has(raw)
      ? rewriteOpenEndedRepeats(source, flags)
      : source;
    pattern = compileConfigRegex(optimized, flags)?.regex ?? null;
    canPrefilter =
      pattern !== null &&
      pattern.source === optimized &&
      pattern.flags === flags &&
      pattern.exec === RegExp.prototype.exec &&
      pattern[Symbol.replace] === RegExp.prototype[Symbol.replace];
  }
  if (pattern && typeof raw === "string" && backendPatterns.shellReferencePreserving.has(raw)) {
    shellReferencePreservingPatterns.add(pattern);
  }
  if (pattern && typeof raw === "string" && backendPatterns.formAware.has(raw)) {
    formAwareEqualsAssignmentPatterns.add(pattern);
  }
  if (
    pattern &&
    typeof raw === "string" &&
    (raw.startsWith(IDENTIFIER_SAFE_TOKEN_BOUNDARY) || backendPatterns.chunkUnsafe.has(raw))
  ) {
    chunkUnsafePatterns.add(pattern);
  }
  if (pattern && typeof raw === "string") {
    if (canonicalBuiltInSources.has(raw)) {
      builtInResolvedPatterns.add(pattern);
    }
    if (canPrefilter && vendorSources.has(raw) && !vendorResolvedPatterns.has(pattern)) {
      const source = pattern.source;
      const exec = pattern.exec;
      const flags = pattern instanceof RegExp ? pattern.flags : undefined;
      const replace = pattern instanceof RegExp ? pattern[Symbol.replace] : undefined;
      vendorResolvedPatterns.set(
        pattern,
        () =>
          pattern.source === source &&
          pattern.exec === exec &&
          (!(pattern instanceof RegExp) ||
            (pattern.flags === flags && pattern[Symbol.replace] === replace)),
      );
    }
    const probe = backendPatterns.prefilters.get(raw);
    if (canPrefilter && probe) {
      setRedactPatternPrefilter(pattern, probe);
    }
  }
  return pattern;
}
function resolvePatterns(value                           )                          {
  if (usesBuiltInRedactPatterns(value)) {
    defaultResolvedPatterns ??= DEFAULT_REDACT_PATTERNS.map(parsePattern).filter(
      (re)                              => Boolean(re),
    );
    return defaultResolvedPatterns;
  }
  // Combined policies: operator patterns composed with the canonical default arrays. Rule
  // identity decides provenance, not array identity: each raw entry that is itself a canonical
  // built-in rule keeps whole-text scanning, while actual operator rules keep bounded scanning.
  // Mark the resolved instances at parse time; the shared compiler can reuse a regex instance.
  const combined = new Set                       ();
  let invalid = !Array.isArray(value);
  for (const raw of Array.isArray(value) ? value : []) {
    const resolved = parsePattern(raw);
    if (resolved) {
      combined.add(resolved);
    } else {
      invalid = true;
    }
  }
  if (invalid) {
    // A malformed policy must keep both usable operator rules and default protection.
    for (const pattern of resolvePatterns()) {
      combined.add(pattern);
    }
    if (!warnedInvalidPatterns) {
      warnedInvalidPatterns = true;
      try {
        console.warn(
          "[openclaw] Ignoring invalid logging.redactPatterns entries; keeping valid patterns and built-in redaction. Fix logging.redactPatterns in your config.",
        );
      } catch {
        // Console capture can re-enter redaction, and a failed warning must not stop masking.
      }
    }
  }
  combined.add(AWS_SECRET_ACCESS_KEY_MATCHER);
  return [...combined];
}
function usesBuiltInRedactPatterns(value                           )          {
  return (
    value === undefined ||
    value === DEFAULT_REDACT_PATTERNS ||
    (Array.isArray(value) && value.length === 0)
  );
}
function normalizeSensitiveKeyName(value        )         {
  const stripped = value.replace(FORM_BODY_KEY_SEPARATOR_RE, "");
  try {
    return decodeURIComponent(stripped)
      .replace(FORM_BODY_KEY_SEPARATOR_RE, "")
      .toLowerCase()
      .replaceAll("-", "_");
  } catch {
    return stripped.toLowerCase().replaceAll("-", "_");
  }
}
function isSensitiveBodyKey(key        )          {
  return (
    isSensitiveUrlQueryParamName(key) ||
    backendPatterns.bodySecretKeys.has(normalizeSensitiveKeyName(key))
  );
}
function hasEncodedOrInvisibleFormKey(key        )          {
  return (
    FORM_BODY_PERCENT_ESCAPE_RE.test(key) || key.replace(FORM_BODY_KEY_OBFUSCATION_RE, "") !== key
  );
}
function visitSensitiveAssignments(
  text        ,
  kind                         ,
  visit                                                        ,
)       {
  if (!text || (kind === "url" && !text.includes("?"))) {
    return;
  }
  if (
    kind === "encoded" &&
    !text.includes("%") &&
    text.replace(FORM_BODY_KEY_OBFUSCATION_RE, "") === text
  ) {
    return;
  }
  if (kind === "context" && !/[=:]/u.test(text)) {
    return;
  }
  const visitPair = (key        , token        , valueOffset        )       => {
    if (kind === "encoded" && !hasEncodedOrInvisibleFormKey(key)) {
      return;
    }
    if (!isSensitiveBodyKey(key)) {
      return;
    }
    const { maskable, maskStart, maskEnd } = splitSecretValueForMask(token);
    visit(valueOffset + maskStart, valueOffset + maskEnd, maskable);
  };
  if (kind === "form") {
    let cursor = 0;
    for (const pair of text.split("&")) {
      const equalsIndex = pair.indexOf("=");
      if (equalsIndex >= 0) {
        visitPair(
          pair.slice(0, equalsIndex),
          pair.slice(equalsIndex + 1),
          cursor + equalsIndex + 1,
        );
      }
      cursor += pair.length + 1;
    }
    return;
  }
  const pattern =
    kind === "url"
      ? URL_QUERY_PAIR_RE
      : kind === "encoded"
        ? ENCODED_FORM_PAIR_RE
        : FORM_BODY_CONTEXT_SINGLE_PAIR_RE;
  const keyIndex = kind === "context" ? 3 : 2;
  // These private synchronous sinks cannot re-enter the scanner. Release regex state on errors too.
  pattern.lastIndex = 0;
  try {
    for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
      const prefix = match[1] ?? "";
      const key = match[keyIndex] ?? "";
      visitPair(key, match[keyIndex + 1] ?? "", match.index + prefix.length + key.length + 1);
    }
  } finally {
    pattern.lastIndex = 0;
  }
}
function redactAssignmentValues(
  text        ,
  kind                         ,
  onEdits                      ,
)         {
  const parts           = [];
  const edits                  = [];
  let cursor = 0;
  visitSensitiveAssignments(text, kind, (start, end, maskable) => {
    const replacement = kind === "url" ? maskToken(maskable) : "***";
    parts.push(text.slice(cursor, start), replacement);
    if (onEdits) {
      edits.push({ start, end, replacement });
    }
    cursor = end;
  });
  if (edits.length > 0) {
    onEdits?.(edits);
  }
  return parts.length > 0 ? parts.join("") + text.slice(cursor) : text;
}
function redactFormBodyLine(text        , onEdits                      )         {
  if (!text.includes("=")) {
    return text;
  }
  const contextRedacted = redactAssignmentValues(
    redactAssignmentValues(text, "encoded", onEdits),
    "context",
    onEdits,
  );
  if (!contextRedacted.includes("&")) {
    return contextRedacted;
  }
  if (FORM_BODY_RE.test(contextRedacted)) {
    return redactAssignmentValues(contextRedacted, "form", onEdits);
  }
  const substringEdits                  = [];
  const redacted = contextRedacted.replace(
    FORM_BODY_SUBSTRING_RE,
    (match, prefix        , body        , offset        ) => {
      const redactedBody = redactAssignmentValues(
        body,
        "form",
        onEdits
          ? (edits) => {
              for (const edit of edits) {
                substringEdits.push({
                  ...edit,
                  start: offset + prefix.length + edit.start,
                  end: offset + prefix.length + edit.end,
                });
              }
            }
          : undefined,
      );
      return redactedBody === body ? match : `${prefix}${redactedBody}`;
    },
  );
  if (substringEdits.length > 0) {
    onEdits?.(substringEdits);
  }
  return redactAssignmentValues(
    redactAssignmentValues(redacted, "encoded", onEdits),
    "context",
    onEdits,
  );
}
function redactFormBody(text        , onEdits                      )         {
  // Every form grammar requires a literal assignment separator, including encoded keys.
  if (!text.includes("=")) {
    return text;
  }
  if (FORM_BODY_LINE_BREAK_SPLIT_RE.test(text)) {
    let offset = 0;
    return text
      .split(FORM_BODY_LINE_BREAK_SPLIT_RE)
      .map((segment) => {
        const result = FORM_BODY_LINE_BREAK_SEGMENT_RE.test(segment)
          ? segment
          : redactFormBodyLine(
              segment,
              onEdits
                ? (edits) =>
                    onEdits(
                      edits.map((edit) => ({
                        ...edit,
                        start: offset + edit.start,
                        end: offset + edit.end,
                      })),
                    )
                : undefined,
            );
        offset += result.length;
        return result;
      })
      .join("");
  }
  return redactFormBodyLine(text, onEdits);
}
function isShellReferenceToKey(key        , value        )          {
  if (!/^[A-Z_][A-Z0-9_]*$/.test(key)) {
    return false;
  }
  const bare = value.match(/^\$([A-Z_][A-Z0-9_]*)$/);
  if (bare) {
    return bare[1] === key;
  }
  const braced = value.match(/^\$\{([A-Z_][A-Z0-9_]*)(?::[-=?+])?\}$/);
  return braced?.[1] === key;
}
function shouldPreserveShellReferenceMatch(match        , token        )          {
  const key = match.match(/\b([A-Z_][A-Z0-9_]*)\b\s*[=:]/)?.[1];
  return key ? isShellReferenceToKey(key, token) : false;
}
function isEmptyShellParameterExpansionTail(token        )          {
  return /^[-=?+]\}$/.test(token);
}
function prepareRedactionCapture(
  { match, groups, input, offset, replacement: policyReplacement }             ,
  pattern                       ,
)                               {
  if (match.includes("PRIVATE KEY-----")) {
    return {
      start: offset,
      end: offset + match.length,
      value: match,
      redact: (target) => ({
        start: target.start,
        end: target.end,
        value: target.value,
        replacement: policyReplacement ?? redactPemBlock(target.value, "…redacted…"),
      }),
    };
  }
  const selected = selectSecretCapture(match, groups);
  if (selected.value === "***") {
    return undefined;
  }
  const tokenIndex =
    selected.value === match ? 0 : getSecretCaptureStart(pattern, input, match, offset, selected);
  if (tokenIndex < 0) {
    return undefined;
  }
  const start = offset + tokenIndex;
  return {
    start,
    end: start + selected.value.length,
    value: selected.value,
    redact: (target) => {
      const token = target.value;
      const formAwareValue = formAwareEqualsAssignmentPatterns.has(pattern)
        ? splitFormAwareCredentialValue(token)
        : { secret: token, suffix: "" };
      // An earlier pass (form-body or quoted-assignment masking) may already have replaced this
      // value with ***; re-masking would strip its quote wrapper around the placeholder.
      if (splitSecretValueForMask(formAwareValue.secret).maskable === "***") {
        return undefined;
      }
      const isShellReferencePattern = shellReferencePreservingPatterns.has(pattern);
      // Preserve shell variable references (e.g. `MY_TOKEN=$MY_TOKEN`) for assignment patterns
      // registered as shell-reference-preserving, so non-secret expansions that merely echo the
      // assignment key are not masked.
      if (
        isShellReferencePattern &&
        (shouldPreserveShellReferenceMatch(match, token) ||
          isEmptyShellParameterExpansionTail(token))
      ) {
        return undefined;
      }
      // Assignment values can legitimately include trailing shell/structural characters
      // (e.g. `${VAR:-default}`); mask the captured token whole so those characters count toward the
      // retained hint instead of being exposed by delimiter-aware masking.
      const masked =
        policyReplacement ??
        (isShellReferencePattern
          ? maskToken(token)
          : `${maskSecretValue(formAwareValue.secret, { hinted: true })}${formAwareValue.suffix}`);
      return { start: target.start, end: target.end, replacement: masked };
    },
  };
}
function redactMatch(match             , pattern                       )         {
  const capture = prepareRedactionCapture(match, pattern);
  const edit = capture?.redact(capture);
  return edit
    ? match.match.slice(0, edit.start - match.offset) +
        edit.replacement +
        match.match.slice(edit.end - match.offset)
    : match.match;
}
export function redactText(
  text        ,
  patterns                         ,
  options    
                          
   ,
)         {
  const finishMeasurement = startRedactionMeasurement("text");
  let outcome                 = "error";
  try {
    let next = redactFormBody(
      redactAssignmentValues(redactStructuredAuthHeaders(text, "***"), "url"),
    );
    let pattern                       ;
    const replace = (match             ) => redactMatch(match, pattern);
    const replaceRegex = (...args           ) => replace(readRedactMatch(args));
    let vendorInput                    ;
    let vendorMatch = false;
    // Built-in rules (linear matchers and regexes) scan whole text: chunking missed
    // credentials that straddled a boundary. Operator-configured regexes keep the bounded
    // chunked scan, whose cost on operator expressions is the measured safeguard.
    for (pattern of patterns) {
      if (vendorResolvedPatterns.get(pattern)?.()) {
        if (vendorInput !== next) {
          vendorInput = next;
          vendorMatch = couldMatchVendorRedactPatterns(next);
        }
        if (!vendorMatch) {
          if (pattern instanceof RegExp) {
            pattern.lastIndex = 0;
          }
          continue;
        }
      }
      next =
        pattern instanceof RegExp &&
        !options?.fullContext &&
        !builtInResolvedPatterns.has(pattern) &&
        !chunkUnsafePatterns.has(pattern)
          ? replacePatternBounded(next, pattern, replaceRegex)
          : replaceRedactPattern(next, pattern, replace, replaceRegex);
    }
    outcome = "ok";
    return next;
  } finally {
    finishMeasurement?.(outcome, text.length, patterns.length);
  }
}
function resolveConfigRedaction()                {
  const cfg = readLoggingConfig();
  return {
    mode: DEFAULT_REDACT_MODE,
    patterns: cfg?.redactPatterns,
  };
}
export function resolveRedactOptions(options                )                        {
  const resolved = options ?? resolveConfigRedaction();
  const mode = resolved.mode === "off" ? "off" : DEFAULT_REDACT_MODE;
  return { mode, patterns: mode === "off" ? [] : resolvePatterns(resolved.patterns) };
}
export function redactSensitiveText(text        , options                )         {
  if (!text) {
    return text;
  }
  const exactRedacted = redactRegisteredSecretValues(text, maskToken);
  return redactSensitiveTextWithOptions(exactRedacted, options ?? resolveConfigRedaction());
}
function redactSensitiveTextWithOptions(
  exactRedacted        ,
  resolvedOptions               ,
)         {
  if (resolvedOptions.mode === "off") {
    return exactRedacted;
  }
  if (
    usesBuiltInRedactPatterns(resolvedOptions.patterns) &&
    !couldMatchDefaultRedactPatterns(exactRedacted)
  ) {
    return exactRedacted;
  }
  const resolved = resolveRedactOptions(resolvedOptions);
  return redactText(exactRedacted, resolved.patterns);
}
export { DEFAULT_REDACT_MODE, backendPatterns, shellReferencePreservingPatterns, builtInResolvedPatterns, vendorResolvedPatterns, vendorSources, chunkUnsafePatterns, canonicalBuiltInSources, formAwareEqualsAssignmentPatterns, defaultResolvedPatterns, warnedInvalidPatterns, FORM_BODY_KEY_OBFUSCATION_RE, FORM_BODY_KEY_SEPARATOR_RE, FORM_BODY_PERCENT_ESCAPE_RE, FORM_BODY_KEY, FORM_BODY_VALUE, URL_QUERY_VALUE, FORM_BODY_PAIR, FORM_BODY_RE, FORM_BODY_SUBSTRING_RE, ENCODED_FORM_PAIR_RE, FORM_BODY_CONTEXT_SINGLE_PAIR_RE, URL_QUERY_PAIR_RE, FORM_BODY_LINE_BREAK_SPLIT_RE, FORM_BODY_LINE_BREAK_SEGMENT_RE, parsePattern, resolvePatterns, usesBuiltInRedactPatterns, normalizeSensitiveKeyName, isSensitiveBodyKey, hasEncodedOrInvisibleFormKey, visitSensitiveAssignments, redactAssignmentValues, redactFormBodyLine, redactFormBody, isShellReferenceToKey, shouldPreserveShellReferenceMatch, isEmptyShellParameterExpansionTail, prepareRedactionCapture, redactMatch, resolveConfigRedaction, redactSensitiveTextWithOptions };