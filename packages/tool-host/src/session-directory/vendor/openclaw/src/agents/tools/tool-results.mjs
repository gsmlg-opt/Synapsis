export function textResult          (text        , details          )                            {
  return {
    content: [{ type: "text", text }],
    details,
  };
}
export function jsonResult          (payload          )                            {
  return textResult(JSON.stringify(payload, null, 2), payload);
}