export function parseAgentSessionKeyParts(sessionKey        )                               {
  if (!sessionKey.startsWith("agent:") && sessionKey.slice(0, 6).toLowerCase() !== "agent:") {
    return null;
  }
  const agentIdEnd = sessionKey.indexOf(":", 6);
  if (agentIdEnd === -1) {
    return null;
  }
  const agentId = sessionKey.slice(6, agentIdEnd).trim();
  const rest = sessionKey.slice(agentIdEnd + 1);
  return agentId && rest && !rest.startsWith(":") ? { agentId, rest } : null;
}