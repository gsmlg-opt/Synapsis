import { stripInternalRuntimeContext } from "../../agents/internal-runtime-context.mjs";
import { stripInboundMetadata } from "./strip-inbound-meta.mjs";
export function stripInternalMetadataForDisplay(text        )         {
  return stripInboundMetadata(stripInternalRuntimeContext(text));
}