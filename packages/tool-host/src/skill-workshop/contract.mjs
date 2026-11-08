import { parseSkillFrontmatter } from './vendor/openclaw/src/skills/loading/frontmatter.mjs';
import { validateSkillFile } from './vendor/openclaw/src/skills/workshop/library.mjs';
import { skillWriteAdvisories } from './vendor/openclaw/src/skills/workshop/skill-lint.mjs';

// This adapter receives inert values only. Core retains all document effects,
// Agent identity, configuration, persistence and catalog publication ownership.
export function evaluate(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('Content validation failed');
  if (request.operation === 'frontmatter') {
    requireText(request.content);
    return parseSkillFrontmatter(request.content);
  }
  if (request.operation === 'advisories') {
    requireText(request.before);
    requireText(request.after);
    return skillWriteAdvisories(request.before, request.after);
  }
  if (request.operation === 'analyze') {
    requireText(request.name);
    requireText(request.filePath);
    requireText(request.content);
    const before = request.before ?? '';
    requireText(before);
    if (request.maxSkillBytes !== undefined &&
        (typeof request.maxSkillBytes !== 'number' || !Number.isFinite(request.maxSkillBytes)))
      throw new Error('Content validation failed');
    const config = request.maxSkillBytes === undefined ? {}
      : { skills: { workshop: { maxSkillBytes: request.maxSkillBytes } } };
    const description = validateSkillFile(config, request.name, request.filePath, request.content);
    return request.filePath === 'SKILL.md'
      ? { frontmatter: parseSkillFrontmatter(request.content), description,
          advisories: skillWriteAdvisories(before, request.content) }
      : { advisories: [] };
  }
  throw new Error('Content validation failed');
}

function requireText(value) {
  if (typeof value !== 'string') throw new Error('Content validation failed');
}
