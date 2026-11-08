// Named host diagnostic boundary for the source validator's catch path. It
// deliberately owns no logging configuration or raw diagnostic disclosure.
// This is not original OpenClaw failure-format/redaction equivalence.
export function formatErrorMessage() {
  return 'Content validation failed';
}
