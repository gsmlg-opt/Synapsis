import { isSessionParticipantIdentity } from "../../packages/gateway-protocol/src/compiled/sender-identity.js";
export function readTranscriptSenderIdentity(value         )                                       {
  if (
    typeof value !== "object" ||
    value === null ||
    !isSessionParticipantIdentity(value) ||
    (value.type !== "profile" && value.type !== "remote" && value.type !== "observation") ||
    Object.values(value).some((part) => part !== null && (!part.trim() || part.length > 512))
  ) {
    return undefined;
  }
  return { ...value };
}