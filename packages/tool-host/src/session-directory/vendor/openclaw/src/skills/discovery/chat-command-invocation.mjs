import { normalizeLowercaseStringOrEmpty, normalizeOptionalLowercaseString } from "../../../packages/normalization-core/src/string-coerce.mjs";
function normalizeSkillCommandLookup(value        )         {
  return normalizeLowercaseStringOrEmpty(value).replace(/[\s_]+/g, "-");
}
function findSkillCommand(
  skillCommands                    ,
  rawName        ,
)                               {
  const normalized = normalizeSkillCommandLookup(rawName);
  if (!normalized) {
    return undefined;
  }
  return skillCommands.find(
    (entry) =>
      normalizeSkillCommandLookup(entry.name) === normalized ||
      normalizeSkillCommandLookup(entry.skillName) === normalized,
  );
}
export function resolveSkillCommandInvocation(params   
                                
                                    
 )                                                      {
  const match = params.commandBodyNormalized.trim().match(/^\/([^\s]+)(?:\s+([\s\S]+))?$/);
  if (!match) {
    return null;
  }
  const commandName = normalizeOptionalLowercaseString(match[1]);
  const invocation =
    commandName === "skill" ? match[2]?.trim().match(/^([^\s]+)(?:\s+([\s\S]+))?$/) : match;
  if (!commandName || !invocation) {
    return null;
  }
  const command =
    commandName === "skill"
      ? findSkillCommand(params.skillCommands, invocation[1] ?? "")
      : params.skillCommands.find(
          (entry) => normalizeOptionalLowercaseString(entry.name) === commandName,
        );
  return command ? { command, args: invocation[2]?.trim() || undefined } : null;
}