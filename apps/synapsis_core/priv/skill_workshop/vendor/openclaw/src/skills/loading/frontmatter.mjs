import { parseFrontmatterBlockResult } from "../../../packages/markdown-core/src/frontmatter.mjs";
export function parseSkillFrontmatter(content        )                         {
  const parsed = parseFrontmatterBlockResult(content);
  const issue = parsed.issues[0];
  if (issue) {
    throw new Error(`invalid frontmatter: ${issue.code}: ${issue.message}`);
  }
  // Cached metadata must not retain the discarded SKILL.md through parser slices.
  // The normalized record contains only strings; copy its keys and values together.
  return structuredClone(parsed.frontmatter);
}