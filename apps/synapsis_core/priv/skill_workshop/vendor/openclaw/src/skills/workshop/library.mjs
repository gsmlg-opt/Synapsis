import { parseSkillFrontmatter } from "../loading/frontmatter.mjs";
import { scanSkillFile, scanSupportFilePath } from "../security/skill-bundle-scan.mjs";
import { resolveSkillWorkshopConfig } from "./config.mjs";
import { MAX_WORKSPACE_SKILL_SUPPORT_FILE_BYTES } from "../lifecycle/workspace-skill-write.mjs";
import { formatErrorMessage } from "../../../../../host-diagnostics.mjs";
export class WorkshopWriteError extends Error {
           name = "WorkshopWriteError";
}
const SKILL_FILE = "SKILL.md";
const MAX_DESCRIPTION_BYTES = 1024;
function validateSkillMarkdown(name        , content        , maxSkillBytes        )         {
  const sizeBytes = Buffer.byteLength(content);
  if (sizeBytes > maxSkillBytes) {
    throw new WorkshopWriteError(
      `SKILL.md is ${sizeBytes} bytes; the limit is ${maxSkillBytes}. Keep SKILL.md to the procedure and move detail into references/<topic>.md with action=write_file.`,
    );
  }
  let frontmatter                        ;
  try {
    frontmatter = parseSkillFrontmatter(content);
  } catch (error) {
    throw new WorkshopWriteError(
      `SKILL.md frontmatter is invalid (${formatErrorMessage(error)}). Start the file with:\n---\nname: ${name}\ndescription: <when to use this skill>\n---`,
    );
  }
  if (frontmatter.name?.trim() !== name) {
    throw new WorkshopWriteError(
      `SKILL.md frontmatter must contain "name: ${name}" (the skill directory name); found ${frontmatter.name ? `"${frontmatter.name}"` : "no name"}.`,
    );
  }
  const description = frontmatter.description?.trim() ?? "";
  const descriptionBytes = Buffer.byteLength(description);
  if (descriptionBytes === 0 || descriptionBytes > MAX_DESCRIPTION_BYTES) {
    throw new WorkshopWriteError(
      `SKILL.md frontmatter "description" must be 1-${MAX_DESCRIPTION_BYTES} bytes (found ${descriptionBytes}). Lead with the situations that should trigger the skill.`,
    );
  }
  return description;
}
function assertSafeContent(name        , filePath        , content        )       {
  const label = `${name}/${filePath}`;
  const finding = scanSkillFile(content, label).find((entry) => entry.severity === "critical");
  if (!finding) {
    return;
  }
  const fix =
    finding.ruleId === "literal-secret"
      ? "Replace the credential with a placeholder such as <API_KEY>; never store real secrets in skills."
      : "Remove or rewrite that line, then retry.";
  throw new WorkshopWriteError(
    `Refused: ${label} line ${finding.line} matches security rule "${finding.ruleId}" (${finding.message}). ${fix}`,
  );
}
function validateSkillFile(
  config                ,
  name        ,
  filePath        ,
  content        ,
)                     {
  if (filePath !== SKILL_FILE && scanSupportFilePath(filePath).length > 0) {
    throw new WorkshopWriteError(
      `Refused: a file path in "${name}" looks like it contains a credential. Name the file after its topic (e.g. "references/api.md"); never store real secrets in skills.`,
    );
  }
  const description =
    filePath === SKILL_FILE
      ? validateSkillMarkdown(name, content, resolveSkillWorkshopConfig(config).maxSkillBytes)
      : undefined;
  if (
    filePath !== SKILL_FILE &&
    Buffer.byteLength(content) > MAX_WORKSPACE_SKILL_SUPPORT_FILE_BYTES
  ) {
    throw new WorkshopWriteError(
      `${filePath} exceeds ${MAX_WORKSPACE_SKILL_SUPPORT_FILE_BYTES} bytes; split it into smaller files.`,
    );
  }
  assertSafeContent(name, filePath, content);
  return description;
}
export { validateSkillFile };