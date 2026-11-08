// Ordinary query projection follows pinned OpenClaw browser-tool.snapshot.ts.
// This host retains JSON metadata and its existing UTF-8/native result budgets;
// it does not add the reference's separate external-text envelope.
const INTERACTIVE_ROLES = new Set(['button', 'checkbox', 'combobox', 'link', 'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'textbox', 'treeitem']);
const BYTE_LIMIT = 262144;
const TRUNCATION_MARKER = '\n[truncated — retry with a smaller maxChars or limit]';

// Formatter-owned attributes follow the lexical parser in pw-role-snapshot.ts;
// strings in names, values and descriptions cannot become reference metadata.
function lineRef(line) {
  const entry = line.match(/^(\s*-\s+)(.*)$/s);
  if (!entry) return undefined;
  const quoted = entry[2].match(/^'((?:[^']|'')*)'(.*)$/s);
  const key = quoted ? quoted[1].replaceAll("''", "'") : entry[2];
  const match = key.match(/^(\w+)(?:\s+("(?:\\.|[^"\\])*"))?(.*)$/s);
  if (!match) return undefined;
  let suffix = match[3];
  if (match[2] === undefined && suffix.startsWith(' /')) {
    const header = quoted ? suffix : suffix.split(/:(?=\s|$)/, 1)[0];
    const literal = header.match(/^ (\/(?:.*\/)?)/s);
    if (literal) suffix = suffix.slice(literal[0].length);
  }
  return suffix.match(/^(?:\s+\[[^\][]*\])*/)?.[0].match(/\[ref=([^\][]+)\]/)?.[1];
}

function prefix(value, maxChars, maxBytes) {
  let chars = 0; let bytes = 0;
  for (const character of value) {
    const size = Buffer.byteLength(character);
    if (chars + character.length > maxChars || bytes + size > maxBytes) break;
    chars += character.length; bytes += size;
  }
  return value.slice(0, chars);
}

function boundedText(value, maxChars) {
  const text = prefix(value, maxChars, BYTE_LIMIT);
  if (text.length === value.length) return { text, truncated: false };
  if (TRUNCATION_MARKER.length > maxChars) return { text, truncated: true };
  return { text: prefix(value, maxChars - TRUNCATION_MARKER.length,
    BYTE_LIMIT - Buffer.byteLength(TRUNCATION_MARKER)) + TRUNCATION_MARKER, truncated: true };
}

export function projectSnapshotQuery(source, args) {
  const query = typeof args.query === 'string' ? args.query.trim() : '';
  if (!query) return source;
  const raw = source.format === 'aria';
  const tokens = query.toLowerCase().split(/\s+/);
  const body = raw
    ? source.nodes.map(node => `- ${node.role} ${JSON.stringify(node.name)} [ref=${node.ref}]${node.value ? ` value=${JSON.stringify(node.value)}` : ''}${node.description ? ` description=${JSON.stringify(node.description)}` : ''}`).join('\n')
    : source.snapshot;
  const matches = body.split('\n').filter(line => {
    const lower = line.toLowerCase();
    return tokens.every(token => lower.includes(token));
  });
  const matchCount = matches.length;
  const summary = matchCount
    ? `${matchCount} matching line(s) in the returned snapshot${source.truncated ? ' (source truncated)' : ''}.`
    : 'No matching lines in the returned snapshot. Refine the query or take a broader snapshot.';
  const maxChars = typeof args.maxChars === 'number' && args.maxChars > 0 ? args.maxChars : 40000;
  const bounded = boundedText(matches.join('\n'), maxChars);
  const lines = bounded.text.split('\n');
  const visible = new Set(lines.map(lineRef).filter(Boolean));
  const formatterRefs = raw ? source.nodes : source.refs;
  const retained = formatterRefs.filter(info => visible.has(info.ref));
  const refs = source.refs.filter(info => visible.has(info.ref));
  const stats = { lines: bounded.text ? lines.length : 0, chars: bounded.text.length,
    refs: retained.length, interactive: retained.filter(info => INTERACTIVE_ROLES.has(info.role)).length };
  return { ...source, snapshot: bounded.text, summary, matchCount, stats, refs, refCount: refs.length,
    ...(typeof source.semantics === 'string' ? { semantics: source.semantics + '; query projection filters the returned source lines and public refs/nodes after full capture; query maxChars applies independently of capture shaping, with native JSON/UTF-8 budgets; retained private handles and full-source delta baseline are unchanged' } : {}),
    ...(raw ? { nodes: retained, nodeCount: retained.length } : {}),
    ...(Object.hasOwn(source, 'newElements') ? { newElements: lines.filter(line => line.endsWith(' [new]') && lineRef(line)).length } : {}),
    truncated: source.truncated || bounded.truncated };
}
