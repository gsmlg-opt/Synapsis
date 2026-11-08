// Body shaping follows OpenClaw 488631c pw-role-snapshot.ts/snapshot-roles.ts.
// Ordinary lines stay lexical Playwright YAML; only formatter-owned ref tokens
// change. Interactive mode deliberately uses the pin's flattened header format.
const INTERACTIVE_ROLES = new Set(['button', 'checkbox', 'combobox', 'link', 'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'textbox', 'treeitem']);
const STRUCTURAL_ROLES = new Set(['application', 'directory', 'document', 'generic', 'grid', 'group', 'ignored', 'list', 'menu', 'menubar', 'none', 'presentation', 'row', 'rowgroup', 'table', 'tablist', 'toolbar', 'tree', 'treegrid']);
const SNAPSHOT_BYTES = 262144;
const indent = line => Math.floor((line.length - line.trimStart().length) / 2);

function parseSnapshotLine(line) {
  const entry = line.match(/^(\s*-\s+)(.*)$/s);
  if (!entry) return null;
  const prefix = entry[1]; const content = entry[2];
  const quoted = content.match(/^'((?:[^']|'')*)'(.*)$/s);
  const key = quoted ? quoted[1].replaceAll("''", "'") : content;
  const match = key.match(/^(\w+)(?:\s+("(?:\\.|[^"\\])*"))?(.*)$/s);
  if (!match) return null;
  const roleRaw = match[1]; let nameToken = match[2]; let suffix = match[3];
  if (nameToken === undefined && suffix.startsWith(' /')) {
    const header = quoted ? suffix : suffix.split(/:(?=\s|$)/, 1)[0];
    const literal = header.match(/^ (\/(?:.*\/)?)/s);
    if (literal) { nameToken = literal[1]; suffix = suffix.slice(literal[0].length); }
  }
  const attributes = suffix.match(/^(?:\s+\[[^\][]*\])*/)?.[0];
  const refMatch = attributes?.match(/\[ref=([^\][]+)\]/);
  const ref = refMatch?.[1];
  let refStart; let refEnd;
  if (ref) {
    const index = key.length - suffix.length + refMatch.index + 5;
    // YAML single-quoted keys double apostrophes; map the decoded key index
    // back to the exact original token without reserializing the key or value.
    const offset = at => prefix.length + (quoted ? 1 + key.slice(0, at).replaceAll("'", "''").length : at);
    refStart = offset(index); refEnd = offset(index + ref.length);
  }
  return { roleRaw, role: roleRaw.trim().toLowerCase(), nameToken, ref, refStart, refEnd, suffix: suffix + (quoted?.[2] ?? '') };
}

function compactTree(records) {
  const entries = []; const stack = [];
  const finish = () => {
    const current = stack.pop();
    current.keep ||= current.hasRef;
    if (current.hasRef && stack.length) stack.at(-1).hasRef = true;
  };
  for (const record of records) {
    const depth = indent(record.line);
    while (stack.length && stack.at(-1).depth >= depth) finish();
    const hasRef = Boolean(record.parsed?.ref);
    const entry = { ...record, depth, hasRef, keep: hasRef || (record.line.includes(':') && !record.line.trimEnd().endsWith(':')) };
    entries.push(entry); stack.push(entry);
  }
  while (stack.length) finish();
  return entries.filter(entry => entry.keep);
}

export function renderAriaYaml(yaml, options, nextRef) {
  let records = [];
  for (const line of yaml.split('\n')) {
    if (options.depth !== undefined && indent(line) > options.depth) continue;
    const parsed = parseSnapshotLine(line);
    if (!parsed) { if (!options.interactive) records.push({ line }); continue; }
    const name = parsed.nameToken?.startsWith('"') ? JSON.parse(parsed.nameToken) : parsed.nameToken;
    const sourceRef = parsed.ref && /^(?:f\d+)?e\d+$|^\d{1,9}$/i.test(parsed.ref) ? parsed.ref : undefined;
    if (options.interactive) {
      if (!INTERACTIVE_ROLES.has(parsed.role) || !sourceRef) continue;
      const header = `- ${parsed.roleRaw}${name ? ` ${JSON.stringify(name)}` : ''} [ref=`;
      const enhanced = `${header}${sourceRef}]${parsed.suffix.replace(` [ref=${sourceRef}]`, '')}`;
      records.push({ line: enhanced, parsed: { ...parsed, refStart: header.length, refEnd: header.length + sourceRef.length }, sourceRef, name });
    } else if (!(options.compact && STRUCTURAL_ROLES.has(parsed.role) && !name)) records.push({ line, parsed, sourceRef, name });
  }
  if (options.compact && !options.interactive) records = compactTree(records);
  if (!records.length || (records.length === 1 && records[0].line === '')) {
    records = [{ line: options.interactive ? '(no interactive elements)' : '(empty)' }];
  }
  const lines = []; const refs = []; const deltaKeys = new Set();
  const newKeys = options.previousKeys === undefined ? undefined : new Set();
  let chars = 0; let bytes = 0; let truncated = false;
  for (const record of records) {
    if (lines.length >= options.limit) { truncated = true; break; }
    const { parsed, sourceRef, name } = record;
    // Candidate aliases may leave monotonic gaps at a budget boundary, matching
    // the existing allocator. Only complete emitted lines publish/bind refs.
    const ref = sourceRef ? nextRef() : undefined;
    const isNew = ref && newKeys !== undefined && !options.previousKeys.has(sourceRef);
    let line = ref ? record.line.slice(0, parsed.refStart) + ref + record.line.slice(parsed.refEnd) : record.line;
    if (isNew) line += ' [new]';
    const separator = lines.length ? 1 : 0;
    const size = Buffer.byteLength(line) + separator;
    if (chars + line.length + separator > options.maxChars || bytes + size > SNAPSHOT_BYTES) { truncated = true; break; }
    lines.push(line); chars += line.length + separator; bytes += size;
    if (ref) {
      refs.push({ ref, role: parsed.role, name: name ?? '', sourceRef });
      deltaKeys.add(sourceRef);
      if (isNew) newKeys.add(sourceRef);
    }
  }
  return { snapshot: lines.join('\n'), refs, truncated, deltaKeys, ...(newKeys === undefined ? {} : { newElements: newKeys.size }) };
}
