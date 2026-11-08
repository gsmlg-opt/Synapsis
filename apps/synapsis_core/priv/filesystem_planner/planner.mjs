import { prepareFileEdit } from './vendor/openclaw/src/agents/sessions/tools/edit-diff.mjs';
import { prepareFileWriteDiff } from './vendor/openclaw/src/agents/sessions/tools/file-diff.mjs';

const REFERENCE_COMMIT = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function fields(value, allowed) {
  if (!record(value) || Object.keys(value).some(key => !allowed.includes(key))) throw new TypeError('Invalid planner input');
}

// A path is a display label passed to the original pure functions. This module
// does not acquire source text, open targets, or authorize filesystem effects.
export function planFilesystem(request) {
  fields(request, ['protocol', 'id', 'operation', 'input']);
  if (request.protocol !== 1 || typeof request.id !== 'string') throw new TypeError('Invalid planner request');
  const input = request.input;
  let result;
  if (request.operation === 'edit') {
    fields(input, ['content', 'edits', 'path']);
    if (typeof input.content !== 'string' || typeof input.path !== 'string' || !Array.isArray(input.edits)) {
      throw new TypeError('Invalid edit input');
    }
    for (const edit of input.edits) {
      fields(edit, ['oldText', 'newText']);
      if (typeof edit.oldText !== 'string' || typeof edit.newText !== 'string') throw new TypeError('Invalid edit');
    }
    result = prepareFileEdit(input.content, input.edits, input.path);
  } else if (request.operation === 'write_diff') {
    fields(input, ['path', 'content', 'beforeText', 'created']);
    if (typeof input.path !== 'string' || typeof input.content !== 'string' ||
        (input.beforeText !== undefined && typeof input.beforeText !== 'string') ||
        (input.created !== undefined && typeof input.created !== 'boolean')) throw new TypeError('Invalid write diff input');
    result = prepareFileWriteDiff(input);
  } else {
    throw new TypeError('Invalid planner operation');
  }
  return {
    protocol: 1,
    id: request.id,
    result: result === undefined ? null : result,
    runtime: {
      node: process.versions.node,
      v8: process.versions.v8,
      unicode: process.versions.unicode,
      icu: process.versions.icu,
      cldr: process.versions.cldr,
      platform: process.platform,
      arch: process.arch,
    },
    referenceCommit: REFERENCE_COMMIT,
    diffVersion: '9.0.0',
  };
}
