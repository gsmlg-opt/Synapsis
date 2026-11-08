import { RUNTIME_CONTEXT_CUSTOM_TYPE } from "../../../llm-core/src/types.mjs";
import { asOptionalRecord } from "../../../normalization-core/src/record-coerce.mjs";
import { getOpenClawSystemUpdateKind } from "../operator-messages.mjs";
export function isRuntimeContextCarrier(message         )                           {
  const candidate = asOptionalRecord(message);
  const details = candidate?.role === "custom" ? asOptionalRecord(candidate.details) : undefined;
  return (
    candidate?.role === "custom" &&
    ((candidate.customType === RUNTIME_CONTEXT_CUSTOM_TYPE &&
      ((details?.source === "openclaw-runtime-context" &&
        details.runtimeContextCarrier !== false) ||
        (details?.source === undefined && details?.runtimeContextCarrier === true))) ||
      getOpenClawSystemUpdateKind(message) === "runtime-context")
  );
}