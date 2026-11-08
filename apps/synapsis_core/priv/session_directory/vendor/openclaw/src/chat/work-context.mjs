import { isRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { asOptionalRecord } from "../../packages/normalization-core/src/record-coerce.mjs";
import { CHAT_WORK_CONTEXT_DETAIL_LIMITS } from "../../packages/gateway-protocol/src/chat-work-context.mjs";
import { CHAT_WORK_CONTEXT_LIMITS } from "../../packages/gateway-protocol/src/chat-work-context.mjs";
export function readChatWorkContext(value         )                              {
  if (!isRecord(value) || typeof value.page !== "string" || !value.page) {
    return undefined;
  }
  const snapshot                  = { page: value.page };
  for (const [key, field] of Object.entries(value)) {
    if (key === "detail") {
      if (!isRecord(field) || Object.keys(field).length > CHAT_WORK_CONTEXT_DETAIL_LIMITS.fields) {
        return undefined;
      }
      const entries                     = [];
      for (const [name, text] of Object.entries(field)) {
        if (
          !name ||
          name.length > CHAT_WORK_CONTEXT_DETAIL_LIMITS.key ||
          typeof text !== "string" ||
          text.length > CHAT_WORK_CONTEXT_DETAIL_LIMITS.value
        ) {
          return undefined;
        }
        entries.push([name, text]);
      }
      snapshot.detail = Object.fromEntries(entries);
      continue;
    }
    if (
      !Object.hasOwn(CHAT_WORK_CONTEXT_LIMITS, key) ||
      typeof field !== "string" ||
      // SAFETY: the short-circuit own-key check above confines key to the limits record.
      field.length > CHAT_WORK_CONTEXT_LIMITS[key                    ]
    ) {
      return undefined;
    }
    // SAFETY: the closed scalar key and its bounded string value were checked above.
    snapshot[key                    ] = field;
  }
  return snapshot;
}
export function readMessageWorkContext(
  message         ,
)                                                           {
  const entry = asOptionalRecord(message);
  if (entry?.role !== "user") {
    return undefined;
  }
  const attached = asOptionalRecord(asOptionalRecord(entry["__openclaw"])?.workContext);
  const snapshot = readChatWorkContext(attached?.snapshot);
  return snapshot
    ? { snapshot, ...(typeof attached?.text === "string" ? { text: attached.text } : {}) }
    : undefined;
}
export function projectChatWorkContextForDisplay(message         )          {
  const attached = readMessageWorkContext(message);
  if (!attached || attached.text === undefined) {
    return message;
  }
  // SAFETY: readMessageWorkContext only succeeds for a non-array record with a user role.
  const original = message                           ;
  // Consume the alternate text before history budgeting; never ship an unbounded
  // duplicate that could bypass truncation or restore a redacted display field.
  const entry                          = {
    ...original,
    __openclaw: {
      ...asOptionalRecord(original["__openclaw"]),
      workContext: { snapshot: attached.snapshot },
    },
  };
  if (Array.isArray(entry.content)) {
    let textSeen = false;
    const content = entry.content.flatMap((block         ) => {
      const item = asOptionalRecord(block);
      if (item?.type !== "text" && item?.type !== "input_text") {
        return [block];
      }
      if (textSeen) {
        return [];
      }
      textSeen = true;
      return [{ ...item, text: attached.text }];
    });
    if (!textSeen && attached.text) {
      content.unshift({ type: "text", text: attached.text });
    }
    return { ...entry, content };
  }
  if (typeof entry.content === "string") {
    return { ...entry, content: attached.text };
  }
  return typeof entry.text === "string" ? { ...entry, text: attached.text } : entry;
}