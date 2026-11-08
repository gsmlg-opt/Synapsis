import { pruneMapToMaxSize } from "../infra/map-size.mjs";
import { groupPluginRecords as groupRecords } from "../plugins/record-groups.mjs";
import { resolveGlobalSingleton } from "../shared/global-singleton.mjs";
import { escapeRegExp } from "../shared/regexp.mjs";
const MIN_SECRET_VALUE_LENGTH = 6;
const MAX_SECRET_VALUES = 512;
const state = resolveGlobalSingleton                              (
  Symbol.for("openclaw.secretRedactionRegistry"),
  () => ({
    registeredValues: new Map              (),
    registeredValueRedactor: undefined,
  }),
);
function invalidateMatcher()       {
  state.registeredValueRedactor = undefined;
}
function registerOneSecretValue(value        )       {
  if (state.registeredValues.delete(value)) {
    state.registeredValues.set(value, true);
    return;
  }
  state.registeredValues.set(value, true);
  pruneMapToMaxSize(state.registeredValues, MAX_SECRET_VALUES);
  invalidateMatcher();
}
export function registerSecretValueForRedaction(value        )       {
  if (value.length < MIN_SECRET_VALUE_LENGTH) {
    return;
  }
  // URL egress percent-encodes injected values; redact that surface form too.
  const encoded = encodeURIComponent(value);
  if (encoded !== value) {
    registerOneSecretValue(encoded);
  }
  // Structured logs serialize credentials, so retain the JSON string-content form
  // for values with escaped characters.
  const jsonEscaped = JSON.stringify(value).slice(1, -1);
  if (jsonEscaped !== value) {
    registerOneSecretValue(jsonEscaped);
  }
  // Keep the raw value newest so bounded-registry eviction cannot drop the
  // active credential while retaining only a transformed representation.
  registerOneSecretValue(value);
}
export function isSecretValueRegisteredForRedaction(value        )          {
  return state.registeredValues.has(value);
}
export function hasRegisteredSecretValuesForRedaction()          {
  return state.registeredValues.size > 0;
}
export function captureSecretRedactionRegistrySnapshot()                                  {
  return { values: [...state.registeredValues.keys()] };
}
export function redactRegisteredSecretValues(
  text        ,
  mask                                          ,
)         {
  if (!text || state.registeredValues.size === 0) {
    return text;
  }
  state.registeredValueRedactor ??= createSecretValueRedactor([...state.registeredValues.keys()]);
  return state.registeredValueRedactor(text, mask);
}
function createSecretValueRedactor(values                   )                      {
  let compiledMatcher                                                                  ;
  let firstChars                         ;
  return (text, mask) => {
    if (!text || values.length === 0) {
      return text;
    }
    let couldMatch = false;
    // Registration can add several surface forms; prepare their probe once on first use.
    firstChars ??= new Set(values.map((value) => value.charAt(0)));
    for (const firstChar of firstChars) {
      if (text.includes(firstChar)) {
        couldMatch = true;
        break;
      }
    }
    if (!couldMatch) {
      return text;
    }
    if (!compiledMatcher) {
      const buckets = groupRecords(
        values.toSorted((left, right) => right.length - left.length),
        (value) => value.slice(0, MIN_SECRET_VALUE_LENGTH),
      );
      // Supported store values can exceed the regex engine's literal span limit.
      // Compile fixed-width prefixes; verify complete values against the text.
      compiledMatcher = {
        prefixes: new RegExp([...buckets.keys()].map(escapeRegExp).join("|"), "g"),
        buckets,
      };
    }
    const { prefixes, buckets } = compiledMatcher;
    const matches                                     = [];
    prefixes.lastIndex = 0;
    for (let match = prefixes.exec(text); match; match = prefixes.exec(text)) {
      const index = match.index;
      const value = buckets.get(match[0])?.find((candidate) => text.startsWith(candidate, index));
      if (value !== undefined) {
        matches.push({ index, value });
      }
      // A rejected prefix may overlap a real match beginning one code unit later.
      prefixes.lastIndex = index + (value?.length ?? 1);
    }
    // Global replacement fixes its matches before callbacks. Nested registration
    // must affect the next/nested call, never the remainder of this one.
    let result = "";
    let cursor = 0;
    for (const match of matches) {
      result += `${text.slice(cursor, match.index)}${mask(match.value, match.index)}`;
      cursor = match.index + match.value.length;
    }
    return result + text.slice(cursor);
  };
}
function resetSecretRedactionRegistryForTest()       {
  state.registeredValues.clear();
  invalidateMatcher();
}
if (process.env.VITEST || process.env.NODE_ENV === "test") {
  (globalThis                                )[
    Symbol.for("openclaw.secretRedactionRegistryTestApi")
  ] = { resetSecretRedactionRegistryForTest };
}
export { MIN_SECRET_VALUE_LENGTH, MAX_SECRET_VALUES, state, invalidateMatcher, registerOneSecretValue, createSecretValueRedactor, resetSecretRedactionRegistryForTest };