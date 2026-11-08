// Scoped AX formatter oracle. Run with node --experimental-vm-modules.
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const REFERENCE = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const browser = 'extensions/browser/src/browser/';
const sha = input => createHash('sha256').update(input).digest('hex');
const facadeDefinitions = {
  './cdp-page-session.js': { path: `${browser}cdp-page-session.ts`, reason: 'Session preparation is a no-op for the synthetic caller-owned CDP session.', exports: { prepareCdpPageSession: async () => {} } },
  './cdp-role-snapshot-dom.js': { path: `${browser}cdp-role-snapshot-dom.ts`, reason: 'Scoped captures skip cursor discovery; iframe frame-ID enrichment returns an empty Map. URL discovery is disabled. Unused cursor/URL functions throw.', exports: {
    findCursorInteractiveElements: () => { throw new Error('Unscoped cursor discovery is outside this oracle'); },
    resolveLinkUrls: () => { throw new Error('URL discovery is outside this oracle'); },
    resolveIframeFrameIds: async () => new Map(),
  } },
  './cdp.helpers.js': { path: `${browser}cdp.helpers.ts`, reason: 'Socket assembly is unavailable; the public caller-owned-session entrypoint executes.', exports: { withCdpSocket: () => { throw new Error('Socket assembly is outside this oracle'); } } },
};

export async function createReferenceRoleOracle(sourceRoot) {
  const source = resolve(sourceRoot);
  const head = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  if (head !== REFERENCE) throw new Error(`Expected OpenClaw ${REFERENCE}, got ${head}`);
  const records = []; const modules = new Map(); const loads = new Map(); const facades = [];
  const pinnedBytes = async path => {
    const bytes = await readFile(resolve(source, path));
    const pinned = execFileSync('git', ['-C', source, 'show', `${REFERENCE}:${path}`], { maxBuffer: 8 * 1024 * 1024 });
    if (!bytes.equals(pinned)) throw new Error(`Changed reference source: ${path}`);
    return bytes;
  };
  const load = path => {
    if (!loads.has(path)) loads.set(path, loadModule(path));
    return loads.get(path);
  };
  const loadModule = async path => {
    if (modules.has(path)) return modules.get(path);
    const bytes = await pinnedBytes(path);
    const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'strip' });
    records.push({ path, sha256: sha(bytes), executableSha256: sha(executable), executed: true });
    const module = new vm.SourceTextModule(executable, { identifier: path });
    modules.set(path, module);
    await module.link(async specifier => {
      const facade = facadeDefinitions[specifier];
      if (facade) {
        const key = `facade:${specifier}`;
        if (!modules.has(key)) {
          const bytes = await pinnedBytes(facade.path);
          records.push({ path: facade.path, sha256: sha(bytes), executed: false, provenanceOnly: true });
          facades.push({ import: specifier, source: facade.path, reason: facade.reason });
          modules.set(key, new vm.SyntheticModule(Object.keys(facade.exports), function () {
            for (const [name, value] of Object.entries(facade.exports)) this.setExport(name, value);
          }, { identifier: key }));
        }
        return modules.get(key);
      }
      if (specifier === 'openclaw/plugin-sdk/expect-runtime') return load('src/plugin-sdk/expect-runtime.ts');
      if (specifier === 'openclaw/plugin-sdk/string-coerce-runtime') return load('packages/normalization-core/src/string-coerce.ts');
      if (specifier.startsWith('./') && specifier.endsWith('.js')) return load(`${browser}${specifier.slice(2, -3)}.ts`);
      throw new Error(`Unconfigured reference import: ${specifier}`);
    });
    return module;
  };
  const module = await load(`${browser}cdp-role-snapshot.ts`);
  await module.evaluate();
  return {
    async snapshot(recipe) {
      const commands = [];
      const send = async (method, params) => {
        commands.push({ method, params });
        if (method === 'Accessibility.queryAXTree') return { nodes: recipe.ignoredRootRecovery ? [] : recipe.nodes };
        if (method === 'Accessibility.getPartialAXTree') return { nodes: [recipe.nodes.find(node => node.backendDOMNodeId === recipe.rootBackendNodeId)] };
        if (method === 'Accessibility.getFullAXTree') return { nodes: recipe.nodes };
        throw new Error(`Unexpected synthetic CDP method: ${method}`);
      };
      const result = await module.namespace.snapshotRoleViaCdpSession({ send, rootBackendNodeId: recipe.rootBackendNodeId, options: recipe.options, recurseIframes: false, urls: false });
      return { result: JSON.parse(JSON.stringify(result)), commands };
    },
    records: () => records.toSorted((a, b) => a.path.localeCompare(b.path)),
    facades: () => facades.toSorted((a, b) => a.import.localeCompare(b.import)),
  };
}

const node = (id, role, name = '', childIds = [], extra = {}) => ({ nodeId: String(id), backendDOMNodeId: id, role: { value: role }, name: { value: name }, childIds: childIds.map(String), ...extra });
const recipe = (name, nodes, options = {}, extra = {}) => ({ name, nodes, rootBackendNodeId: nodes[0].backendDOMNodeId, options, ...extra });
const bfs = [node(1, 'generic', '', [2, 3]), node(2, 'group', '', [4]), node(3, 'button', 'Repeat'), node(4, 'button', 'Repeat')];
export const recipes = [
  recipe('duplicates-unique-mixed-roles-and-names', [node(1, 'generic', '', [2, 3, 4, 5, 6, 7, 8]), node(2, 'button', 'Save'), node(3, 'button', 'Save'), node(4, 'link', 'Save'), node(5, 'button', 'Other'), node(6, 'link', 'Save'), node(7, 'button'), node(8, 'button')]),
  recipe('raw-bfs-versus-render-dfs', bfs),
  recipe('depth-filter-retains-original-ordinal', bfs, { maxDepth: 0 }),
  recipe('interactive-flattens-after-ordinal-assignment', bfs, { interactive: true }),
  recipe('compact-retains-depth-and-ordinal', [node(1, 'main', 'Workspace', [2, 3]), ...bfs.slice(1)], { compact: true }),
  recipe('transparent-root-and-children', [node(1, 'generic', '', [2, 3]), node(2, 'presentation', '', [4]), node(3, 'button', 'Same'), node(4, 'button', 'Same')]),
  recipe('ignored-root-native-recovery', [node(1, 'none', '', [2, 3], { ignored: true, frameId: 'synthetic-frame' }), node(2, 'group', '', [4]), node(3, 'button', 'Recovered'), node(4, 'button', 'Recovered')], {}, { ignoredRootRecovery: true }),
  recipe('scoped-leaf-iframe', [node(1, 'generic', '', [2, 3]), node(2, 'Iframe', 'Local frame'), node(3, 'Iframe', 'Local frame')]),
  recipe('empty-transparent-root', [node(1, 'generic')]),
  recipe('interactive-empty', [node(1, 'generic', '', [2]), node(2, 'heading', 'Report')], { interactive: true }),
  recipe('compact-empty', [node(1, 'generic', '', [2]), node(2, 'group')], { compact: true }),
  recipe('states-values-and-whitespace', [node(1, 'main', ' Workspace ', [2, 3, 4, 5]), node(2, 'textbox', ' Notes\nline ', [], { value: { value: 'first\nsecond "quoted"' }, properties: [{ name: 'invalid', value: { value: 'grammar' } }] }), node(3, 'checkbox', 'Choice', [], { properties: [{ name: 'checked', value: { value: 'mixed' } }, { name: 'disabled', value: { value: true } }] }), node(4, 'heading', 'Title', [], { properties: [{ name: 'level', value: { value: 2 } }] }), node(5, 'tab', ' Current ', [], { properties: [{ name: 'expanded', value: { value: 'true' } }, { name: 'pressed', value: { value: 'mixed' } }, { name: 'selected', value: { value: true } }] })]),
];

async function main() {
  const source = process.argv[2] ?? '/tmp/openclaw-488631c';
  const output = process.argv[3] ?? resolve(dirname(fileURLToPath(import.meta.url)), '../../packages/tool-host/test/fixtures/browser-native-role-format.json');
  const oracle = await createReferenceRoleOracle(source);
  const vectors = [];
  for (const input of recipes) vectors.push({ ...input, expected: await oracle.snapshot(input) });
  const result = { referenceCommit: REFERENCE, scriptSha256: sha(await readFile(fileURLToPath(import.meta.url))), sourceRecords: oracle.records(), facades: oracle.facades(),
    importRedirections: { 'openclaw/plugin-sdk/expect-runtime': 'src/plugin-sdk/expect-runtime.ts', 'openclaw/plugin-sdk/string-coerce-runtime': 'packages/normalization-core/src/string-coerce.ts' },
    boundaries: [
      'Complete cdp-role-snapshot.ts executes through public snapshotRoleViaCdpSession, including private pre-render ordinal assignment and scoped AX recovery. Complete tree, formatter/finalizer, role sets, depth and URL appendix modules execute after type stripping only.',
      'All source bytes match the exact Git commit. Facaded platform sources are provenance-only and are not claimed as executed. SDK imports redirect to complete pinned implementation modules.',
      'Synthetic successful scoped AX responses only; no real CDP driver/socket/DOM assembly, page-wide cursor discovery, iframe enrichment/recursion, URL discovery, real providers or Chromium execution.',
      'Equivalence covers scoped native text and source-assigned backend identities/ordinals. Local whole-line budgets, alias spelling, delta summaries, URL/label appendices and host cleanup remain separate functional checks.',
      'The local formatter preserves leading depth indentation when compact shaping suppresses initial structural lines; the pin finalizes joined text with trim(). The compact equivalence vector uses a visible main root, so this intentional existing boundary is not claimed as complete text parity.',
    ], vectors };
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ output, vectors: vectors.length, sources: result.sourceRecords.length, facades: result.facades.length })}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
