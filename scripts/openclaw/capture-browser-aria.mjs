// Body-shaping oracle only: execute complete pinned modules, with types stripped.
// Run: node --experimental-vm-modules scripts/openclaw/capture-browser-aria.mjs [sourceRoot] [output]
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const REFERENCE = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const sha = input => createHash('sha256').update(input).digest('hex');
const browser = 'extensions/browser/src/browser/';

export async function createReferenceAriaOracle(sourceRoot) {
  const source = resolve(sourceRoot);
  const head = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  if (head !== REFERENCE) throw new Error(`Expected OpenClaw ${REFERENCE}, got ${head}`);
  const records = []; const modules = new Map();
  const load = async path => {
    if (modules.has(path)) return modules.get(path);
    const bytes = await readFile(resolve(source, path));
    const pinned = execFileSync('git', ['-C', source, 'show', `${REFERENCE}:${path}`], { maxBuffer: 8 * 1024 * 1024 });
    if (!bytes.equals(pinned)) throw new Error(`Changed reference source: ${path}`);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'strip' });
    records.push({ path, sha256: sha(bytes), executableSha256: sha(executable), executed: true });
    const module = new vm.SourceTextModule(executable, { identifier: path });
    modules.set(path, module);
    await module.link(specifier => {
      if (specifier === './snapshot-roles.js') return load(`${browser}snapshot-roles.ts`);
      // SDK entrypoint redirections execute the complete implementation modules.
      if (specifier === 'openclaw/plugin-sdk/expect-runtime') return load('src/plugin-sdk/expect-runtime.ts');
      if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return load('packages/normalization-core/src/string-coerce.ts');
      throw new Error(`Unconfigured reference import: ${specifier}`);
    });
    return module;
  };
  const module = await load(`${browser}pw-role-snapshot.ts`);
  await module.evaluate();
  return {
    shape: (yaml, options) => JSON.parse(JSON.stringify(module.namespace.buildRoleSnapshotFromAiSnapshot(yaml, options))),
    findRef: line => module.namespace.findRoleSnapshotLineRef(line),
    records: () => records.toSorted((a, b) => a.path.localeCompare(b.path)),
  };
}

export const recipes = [
  { name: 'ordinary-properties-states', yaml: '- main [ref=e1]:\n  - heading "Current work" [level=2] [ref=e2]\n  - link "Project" [ref=e3] [cursor=pointer]:\n    - /url: /projects/current\n  - textbox "Notes" [ref=e4]:\n    - /placeholder: Write here\n    - text: initial value\n  - checkbox "Selected" [checked=mixed] [ref=e5]\n  - button "Expand" [disabled] [expanded] [ref=e6]', options: {} },
  { name: 'multiline-and-scalars', yaml: '- paragraph [ref=e7]: "First line\\nSecond line: more detail"\n- text: "A colon: and a \\"quotation\\""\n- textbox "Memo" [ref=e8]: "line one\\nline two"', options: {} },
  { name: 'yaml-quoted-and-json-names', yaml: '- \'button "Save: today\'\'s work" [ref=e9]\'\n- button "Say \\"hello\\"" [ref=e10]\n- \'link "Folder: / documents" [ref=f2e11]\':\n  - /url: /folder/documents', options: {} },
  { name: 'literal-slash-names', yaml: '- button /Save now/ [ref=e12] [pressed]\n- \'button /Today\'\'s: report/ [ref=f3e13]\'\n- textbox "Path" [ref=e14]: /folder/value/', options: {} },
  { name: 'interactive-shaping', yaml: '- main [ref=e20]:\n  - heading "Title" [ref=e21]\n  - \'button "Save: today\'\'s work" [ref=e22]\'\n  - button /Confirm/ [ref=f4e23] [pressed]\n  - link "Help" [ref=e24]:\n    - /url: /help', options: { interactive: true } },
  { name: 'compact-branches', yaml: '- generic [ref=e30]:\n  - group [ref=e31]:\n    - button "Keep" [ref=e32]\n- paragraph:\n  - text: Meaningful text\n- generic:\n  - generic:', options: { compact: true } },
  { name: 'compact-inline-structural-scalar', yaml: '- generic [ref=e33]: Ordinary generic text\n- group [ref=e34]: Group sole text\n- paragraph [ref=e35]: Meaningful paragraph', options: { compact: true } },
  { name: 'depth', yaml: '- main [ref=e40]:\n  - group [ref=e41]:\n    - button "Deep" [ref=e42]\n  - button "Shallow" [ref=f5e43]', options: { maxDepth: 1 } },
  { name: 'compact-interactive-depth', yaml: '- main [ref=e50]:\n  - button "Visible" [ref=e51]\n  - group:\n    - button "Deep" [ref=f6e52]', options: { compact: true, interactive: true, maxDepth: 1 } },
  { name: 'blank', yaml: '', options: {} },
  { name: 'empty-compact', yaml: '- generic:\n  - group:', options: { compact: true } },
  { name: 'no-interactive', yaml: '- heading "Report" [ref=e60]\n- paragraph: Some content', options: { interactive: true } },
];

async function main() {
  const source = process.argv[2] ?? '/tmp/openclaw-488631c';
  const output = process.argv[3] ?? resolve(dirname(fileURLToPath(import.meta.url)), '../../packages/tool-host/test/fixtures/browser-aria-yaml.json');
  const oracle = await createReferenceAriaOracle(source);
  const vectors = recipes.map(recipe => ({ ...recipe, expected: oracle.shape(recipe.yaml, recipe.options) }));
  const result = { referenceCommit: REFERENCE, scriptSha256: sha(await readFile(fileURLToPath(import.meta.url))),
    sourceRecords: oracle.records(), facades: [],
    importRedirections: { 'openclaw/plugin-sdk/expect-runtime': 'src/plugin-sdk/expect-runtime.ts',
      'openclaw/plugin-sdk/string-coerce-runtime': 'packages/normalization-core/src/string-coerce.ts' },
    boundaries: ['Complete pinned pw-role-snapshot.ts and snapshot-roles.ts execute after type stripping only; all module bytes verified against the exact Git pin.',
      'SDK imports redirect to complete pinned implementation modules; no SDK behavior facade or handpicked local shaping algorithm.',
      'Frozen inputs are synthetic successful formatter-shaped YAML vectors; slash-delimited names additionally cover the pinned codegen/MCP lexical parser, not a claim that ordinary AI mode emits slash names.',
      'Oracle covers buildRoleSnapshotFromAiSnapshot body shaping only. Browser route assembly, finalizer, delta summary, URL appendix, local budgets and alias spelling are outside oracle equivalence.'], vectors };
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ output, vectors: vectors.length, sources: result.sourceRecords.length })}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
