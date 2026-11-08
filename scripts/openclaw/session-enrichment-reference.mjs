// Ordinary session enrichment oracle: actual pinned source, never helper replicas.
// Service ownership, transcript reads and tool callback assembly are outside this oracle.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, relative, resolve, sep } from 'node:path';
import vm from 'node:vm';

export const SESSION_ENRICHMENT_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const normalization = 'packages/normalization-core/src/';
const paths = {
  display: 'src/gateway/session-display-projection.ts',
  markdown: normalization + 'markdown-plain-text.ts',
  goal: 'src/gateway/derive-goal-session-title.ts',
  title: 'src/gateway/session-utils-core.ts',
  inline: 'src/agents/tools/chat-history-text.ts',
  postfilter: 'src/agents/tools/sessions-list-tool.ts',
};
const hash = value => createHash('sha256').update(value).digest('hex');

// Each projection keeps complete original functions/constants and only replaces
// their module import envelope. There is no rewritten helper body.
const projections = {
  [paths.title]: {
    functions: ['deriveSessionTitle', 'prepareSessionTitleRead'],
    imports: [
      'import { normalizeOptionalString } from "@openclaw/normalization-core/string-coerce";',
      'import { deriveGoalSessionTitle } from "./derive-goal-session-title.js";',
    ],
    excludes: 'Uncalled archive, cost, registry and child-owner operations.',
  },
  'src/gateway/chat-display-projection.sanitize.ts': {
    functions: ['prepareAssistantHistoryMessage'],
    imports: [
      'import { asOptionalObjectRecord as readObjectRecord } from "@openclaw/normalization-core/record-coerce";',
      'import { prepareAgentRunReplyText } from "../agents/agent-run-terminal-reply.js";',
      'import { readAssistantTextBlocksForPhase, readTerminalSourceReplyDeliveryMirror } from "../shared/chat-message-content.js";',
      'import { isProjectedForwardedMessage } from "./chat-display-projection.helpers.js";',
    ],
    excludes: 'Uncalled full history sanitizer, tool/media payload projection and workspace conflict services.',
  },
  'src/agents/agent-run-terminal-reply.ts': {
    functions: ['prepareAgentRunReplyText'],
    imports: [
      'import { stripMixedSilentReplyTokens } from "../auto-reply/reply/mixed-silent-reply-tokens.js";',
      'import { isSilentReplyText } from "../auto-reply/tokens.js";',
    ],
    excludes: 'Uncalled terminal receipt, lifecycle, route-change and outbound presentation operations.',
  },
  [paths.inline]: {
    functions: ['stripToolMessages'],
    imports: ['import { NESTED_TOOL_ACTIVITY_CUSTOM_TYPE } from "../../sessions/nested-tool-activity.js";'],
    excludes: 'Uncalled stored-assistant text sanitizer/rendering.',
  },
  'src/sessions/nested-tool-activity.ts': {
    constants: ['NESTED_TOOL_ACTIVITY_CUSTOM_TYPE'], imports: [],
    excludes: 'Uncalled Zod validation and nested-activity persistence.',
  },
};

// These exact import edges belong to uncalled branches of whole modules.
// A call records evidence and throws, so no observed output can use a facade.
const facades = [
  ['src/gateway/chat-display-projection.helpers.ts', '../media/media-facts.js', ['isMeaningfulMediaFact', 'readPersistedMediaFacts']],
  ['src/gateway/chat-display-projection.helpers.ts', '../media/parse-output.js', ['isRelativeAssistantMediaReference', 'splitMediaOutput']],
  ['src/sessions/session-title-source.ts', '../skills/discovery/chat-command-invocation.js', ['resolveSkillCommandInvocation']],
];

export async function createSessionEnrichmentReference(sourceRoot = process.env.OPENCLAW_SESSION_SOURCE ?? '/tmp/openclaw-488631c') {
  const root = realpathSync(sourceRoot);
  const git = args => execFileSync('git', ['-C', root, ...args], { timeout: 10_000, maxBuffer: 8 * 1024 * 1024 });
  const verifyCheckout = () => {
    assert.equal(realpathSync(git(['rev-parse', '--show-toplevel']).toString().trim()), root);
    assert.equal(git(['rev-parse', 'HEAD']).toString().trim(), SESSION_ENRICHMENT_PIN);
    assert.equal(git(['status', '--porcelain', '--untracked-files=no']).toString(), '', 'clean tracked reference');
  };
  verifyCheckout();
  const context = vm.createContext({ __facadeCalls: [] });
  const modules = new Map();
  const sources = new Map();
  const transforms = [];
  const regions = [];
  const imports = [];
  const facadeEdges = [];
  const calls = [];

  function source(path) {
    if (sources.has(path)) return sources.get(path).content;
    const file = resolve(root, path);
    assert.ok(file.startsWith(root + sep));
    assert.equal(realpathSync(file), file);
    const bytes = readFileSync(file);
    assert.ok(bytes.equals(git(['show', SESSION_ENRICHMENT_PIN + ':' + path])), 'exact pinned blob: ' + path);
    const content = bytes.toString('utf8');
    assert.ok(Buffer.from(content).equals(bytes), 'complete UTF-8 source: ' + path);
    sources.set(path, {
      path, content, bytes: bytes.length, sha256: hash(bytes),
      gitBlob: git(['rev-parse', SESSION_ENRICHMENT_PIN + ':' + path]).toString().trim(),
    });
    return content;
  }

  function region(path, pattern, label) {
    const original = source(path);
    const matches = [...original.matchAll(pattern)];
    assert.equal(matches.length, 1, 'exactly one complete source region: ' + label);
    const match = matches[0];
    const selected = match[0];
    regions.push({ path, label, startByte: Buffer.byteLength(original.slice(0, match.index)),
      endByte: Buffer.byteLength(original.slice(0, match.index + selected.length)), sha256: hash(selected) });
    return selected;
  }

  function module(path) {
    if (modules.has(path)) return modules.get(path);
    let selected = source(path);
    const projection = projections[path];
    if (projection) {
      const selections = [
        ...(projection.functions ?? []).map(name => region(path, new RegExp('^export function ' + name + '\\b[\\s\\S]*?^\\}', 'gm'), name)),
        ...(projection.constants ?? []).map(name => region(path, new RegExp('^export const ' + name + ' = [^\\n]+;', 'gm'), name)),
      ];
      selected = [...projection.imports, ...selections].join('\n');
    }
    const executable = stripTypeScriptTypes(selected, { mode: 'strip', sourceMap: false });
    transforms.push({ path, kind: projection ? 'exact-source-regions' : 'complete-module',
      sourceSha256: sources.get(path).sha256, selectedSha256: hash(selected), executableSha256: hash(executable),
      transformation: 'node:module.stripTypeScriptTypes(mode=strip,sourceMap=false)',
      ...(projection ? { importEnvelope: projection.imports, excludes: projection.excludes } : {}) });
    const result = new vm.SourceTextModule(executable, { context, identifier: path });
    modules.set(path, result);
    return result;
  }

  const tsconfig = JSON.parse(source('tsconfig.json')).compilerOptions.paths;
  function link(specifier, importer) {
    const owner = importer.identifier;
    const facade = facades.find(([path, edge]) => path === owner && edge === specifier);
    if (facade) {
      const id = 'uncalled:' + owner + ':' + specifier;
      if (!modules.has(id)) {
        const code = facade[2].map(name => `export function ${name}(){__facadeCalls.push(${JSON.stringify({ importer: owner, specifier, export: name })});throw Error("Uncalled reference facade invoked");}`).join('\n');
        facadeEdges.push({ importer: owner, specifier, exports: facade[2], kind: 'throwing-uncalled-import-edge', executableSha256: hash(code) });
        modules.set(id, new vm.SourceTextModule(code, { context, identifier: id }));
      }
      return modules.get(id);
    }
    let target;
    if (specifier.startsWith('.')) {
      target = relative(root, resolve(dirname(resolve(root, owner)), specifier)).replace(/\.js$/, '.ts');
    } else if (specifier === '@openclaw/normalization-core' || specifier.startsWith('@openclaw/normalization-core/')) {
      const actual = tsconfig[specifier];
      assert.equal(actual?.length, 1, 'exact original tsconfig alias: ' + specifier);
      target = actual[0].replace(/^\.\//, '');
      assert.ok(target.startsWith(normalization), 'normalization alias target');
    } else {
      throw Error('Unapproved reference import: ' + owner + ' -> ' + specifier);
    }
    imports.push({ importer: owner, specifier, target });
    return module(target);
  }

  for (const path of Object.values(paths).filter(path => path !== paths.postfilter)) {
    const entry = module(path);
    if (entry.status === 'unlinked') await entry.link(link);
    if (entry.status === 'linked') await entry.evaluate({ timeout: 1000 });
    assert.equal(entry.status, 'evaluated');
  }

  // Preserve the list callback's exact post-fetch sequence; only the async
  // gateway/pMap envelope is excluded. This cannot fetch or refill history.
  const postfilter = region(paths.postfilter,
    /^            const rawMessages = Array\.isArray\(history\?\.messages\)[\s\S]*?filtered\.slice\(-messageLimit\) : filtered;/gm,
    'sessions-list inline postfilter sequence');
  const postfilterCode = 'import { stripToolMessages } from "./chat-history-text.js";\nexport function postfilterInline(history, messageLimit) {\nconst target = { row: {} };\n' + postfilter + '\nreturn target.row.messages;\n}';
  const inline = new vm.SourceTextModule(postfilterCode, { context, identifier: 'src/agents/tools/reference-inline-postfilter.ts' });
  await inline.link(link);
  await inline.evaluate({ timeout: 1000 });
  modules.set('inlinePostfilter', inline);
  transforms.push({ path: paths.postfilter, kind: 'exact-statement-sequence',
    sourceSha256: sources.get(paths.postfilter).sha256, executableSha256: hash(postfilterCode),
    excludes: 'Gateway history fetch, async pMap, row ownership and final list result assembly.' });

  function call(entry, name, args = []) {
    const path = paths[entry] ?? entry;
    const target = modules.get(path);
    assert.ok(target, 'loaded module: ' + entry);
    assert.equal(typeof target.namespace[name], 'function', 'source function: ' + name);
    context.__function = target.namespace[name];
    context.__args = args;
    calls.push({ entry, path, export: name });
    return new vm.Script('__function(...__args)').runInContext(context, { timeout: 1000 });
  }

  function evidence() {
    verifyCheckout();
    assert.equal(context.__facadeCalls.length, 0, 'no uncalled facade was invoked');
    for (const row of sources.values()) assert.equal(hash(readFileSync(resolve(root, row.path))), row.sha256, 'source unchanged: ' + row.path);
    return {
      reference: { commit: SESSION_ENRICHMENT_PIN, tree: git(['rev-parse', SESSION_ENRICHMENT_PIN + '^{tree}']).toString().trim(), trackedClean: true },
      sources: [...sources.values()].map(({ content: _, ...row }) => row).sort((a, b) => a.path.localeCompare(b.path)),
      transforms, regions, imports, facadeEdges, facadeCalls: Array.from(context.__facadeCalls), calls: [...calls],
      harness: { path: 'scripts/openclaw/session-enrichment-reference.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
      exclusions: [
        'No gateway, storage reader, generation/currentness, lifecycle, provider, permission, service or full tool callback execution.',
        'No managed-media directive parser/facts branch or slash-skill invocation execution; those import-edge facades must remain uncalled.',
        'Forwarded text provenance can run through real source; forwarded managed-media exceptions remain outside coverage.',
      ],
    };
  }
  return { call, evidence };
}
