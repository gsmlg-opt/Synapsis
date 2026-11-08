// Construction-only evidence from unchanged pinned session modules.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, relative } from 'node:path';
import { FactoryHarness, describeSchema, representativeContexts } from './capture-recipes.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const tools = 'src/agents/tools/';
const protocol = 'packages/gateway-protocol/src/';
const normalization = 'packages/normalization-core/src/';
const list = tools + 'sessions-list-tool.ts';
const history = tools + 'sessions-history-tool.ts';
const status = tools + 'session-status-tool.ts';
const wrapper = tools + 'gateway-caller-context.ts';
const helpers = tools + 'sessions-helpers.ts';
const schema = 'src/agents/schema/typebox.ts';
const descriptions = 'src/agents/tool-description-presets.ts';
export const SESSION_FACTORY_SOURCES = [list, history, status];
const protocolFiles = [
  'chat-work-context', 'client-info', 'human-mention-limits', 'secret-ref-contract', 'session-communication', 'session-limits',
  'schema/chat-history-constants', 'schema/closed-object', 'schema/human-mentions', 'schema/logs-chat', 'schema/primitives',
  'schema/session-classification', 'schema/session-participant', 'schema/sessions-activity-summary', 'schema/sessions-communication',
  'schema/sessions-list', 'schema/sessions-provider-review', 'schema/sessions-row', 'schema/sessions-sharing-values',
  'schema/sessions-sharing-constants', 'schema/string-literal-union', 'schema/user-profile-constants',
].map(path => protocol + path + '.ts');
const allowedSources = [...SESSION_FACTORY_SOURCES, wrapper, helpers, schema, descriptions, tools + 'session-status-tool.schema.ts',
  'src/agents/schema/string-enum.ts', 'src/infra/outbound/channel-target.ts', 'src/shared/lazy-promise.ts',
  ...protocolFiles, ...['string-coerce', 'record-coerce', 'utf16-slice'].map(path => normalization + path + '.ts')];
const wrapperBindings = ['withGatewayPersonalToolUser', 'readToolStringParam', 'asNonArrayRecord', 'getGatewayToolCallerIdentity', 'resolveGatewayToolOperatorSelection'];
const helperExecutionExports = {
  [list]: ['createSessionVisibilityRowChecker', 'classifySessionListKind', 'deriveChannel', 'resolveDisplaySessionKey', 'resolveInternalSessionKey', 'resolveSessionToolContext'],
  [history]: ['createSessionVisibilityRowChecker', 'formatSessionToolAccessDenial', 'isSessionToolMainAlias', 'resolveSessionReference', 'resolveSessionToolAccess', 'resolveSessionToolContext', 'resolveVisibleSessionReference', 'shouldResolveSessionIdInput'],
  [status]: ['formatSessionToolAccessDenial', 'resolveCurrentSessionClientAlias', 'resolveSessionReference', 'resolveSessionToolAccess', 'resolveSessionToolContext', 'resolveVisibleSessionReference', 'shouldResolveSessionIdInput'],
};
// Per-importer execution-only exports. No unknown import is synthesized.
const serviceRules = [
  [list, 'p-map', ['default']],
  [list, 'typebox/value', ['Value.Check']],
  [list, '../../gateway/session-utils-core.js', ['deriveSessionTitle', 'prepareSessionTitleRead']],
  [list, '../../routing/session-key.js', ['classifySessionKeyShape', 'isIncognitoSessionKey']],
  [list, '../../sessions/session-state-events.js', ['getSessionStateVersions']],
  [list, '../agent-scope.js', ['resolveSessionAgentIds']],
  [list, './chat-history-text.js', ['stripToolMessages']],
  [list, './common.js', ['jsonResult', 'readNonNegativeIntegerParam', 'readPositiveIntegerParam', 'readStringArrayParam', 'readToolStringParam']],
  [list, './in-process-gateway.js', ['callAgentToolGatewayRequest', 'getInProcessGatewayToolContext', 'hasGatewayToolRoutingContext']],
  [list, './scoped-session-access.js', ['resolveSessionToolTargetAgentId']],
  [history, '@openclaw/normalization-core/number-coercion', ['asPositiveSafeInteger']],
  [history, '../../config/sessions/session-store-owner.js', ['resolvePersistedSessionStoreOwnerForKey']],
  [history, '../../gateway/session-transcript-readers.js', ['capArrayByJsonBytes']],
  [history, '../../infra/json-utf8-bytes.js', ['jsonUtf8Bytes']],
  [history, '../../routing/session-key.js', ['parseAgentSessionKey']],
  [history, '../../utils.js', ['truncateUtf16Safe']],
  [history, '../agent-scope.js', ['resolveSessionAgentId', 'resolveSessionAgentIds']],
  [history, './chat-history-text.js', ['stripToolMessages']],
  [history, './common.js', ['jsonResult', 'readNonNegativeIntegerParam', 'readPositiveIntegerParam', 'readToolStringParam', 'ToolInputError']],
  [history, './in-process-gateway.js', ['callAgentToolGatewayRequest']],
  [history, './scoped-session-access.js', ['resolveSessionToolTargetAgentId', 'runWithScopedSessionAccess']],
  [status, '../../config/sessions.js', ['resolveSessionStorePathCore']],
  [status, '../../routing/session-key.js', ['buildAgentMainSessionKey', 'isIncognitoSessionKey', 'parseAgentSessionKey', 'resolveAgentIdFromSessionKey']],
  [status, '../../sessions/session-state-events.js', ['getSessionStateVersion', 'listSessionStateEventsSince']],
  [status, '../../utils/delivery-context.read.js', ['deliveryContextFromSession', 'sessionDeliveryChannel', 'sessionDeliveryOrigin']],
  [status, '../../utils/delivery-context.shared.js', ['normalizeDeliveryContext']],
  [status, '../../utils/message-channel.js', ['isDeliverableMessageChannel', 'normalizeMessageChannel']],
  [status, '../agent-scope.js', ['resolveAgentDir', 'resolveAgentWorkspaceDir', 'resolveSessionAgentIds']],
  [status, '../model-selection.js', ['resolveDefaultModelForAgent']],
  [status, '../model-thinking-default.js', ['resolveThinkingDefault']],
  [status, '../prepared-model-catalog.js', ['loadPublishedPreparedModelCatalog']],
  [status, '../session-model-ref.js', ['resolveSessionModelIdentityRef']],
  [status, './common.js', ['readNonNegativeIntegerParam', 'readToolStringParam', 'textResult']],
  [status, './in-process-gateway.js', ['callAgentToolGatewayRequest', 'hasGatewayToolRoutingContext']],
  [status, './scoped-session-access.js', ['resolveSessionToolTargetAgentId', 'runWithScopedSessionAccess']],
  [status, './session-status-capabilities.js', ['formatSessionCapabilities', 'resolveSessionCapabilities']],
  [status, './session-status-model.js', ['patchSessionStatusModel', 'withActiveStatusModelIdentity']],
  [status, './session-status-session-resolve.js', ['listImplicitDefaultDirectFallbackKeys', 'resolveImplicitCurrentSessionFallback', 'resolveSessionStatusEntry', 'resolveStoreScopedRequesterKey']],
  [status, './session-status-state-changes.js', ['compactSessionStateChanges', 'formatSessionStateChanges']],
];
const aliases = [
  [list, 'string-coerce', ['readStringValue']],
  [status, 'string-coerce', ['readStringValue']],
  [history, 'record-coerce', ['asOptionalRecord']],
  [protocol + 'client-info.ts', 'string-coerce', ['normalizeOptionalLowercaseString']],
  [protocol + 'schema/logs-chat.ts', 'record-coerce', ['asOptionalRecord']],
  [protocol + 'schema/logs-chat.ts', 'utf16-slice', ['truncateUtf16Safe']],
];

function selectionsFor(original, regions) {
  const lines = original.split(/(?<=\n)/);
  return regions.map(([startLine, endLine]) => {
    const before = lines.slice(0, startLine - 1).join('');
    const selected = lines.slice(startLine - 1, endLine).join('');
    return { selection: { kind: 'source-lines', startLine, endLine, startByte: Buffer.byteLength(before),
      endByte: Buffer.byteLength(before + selected), sha256: hash(selected) }, selected };
  });
}

class SessionFactoryHarness extends FactoryHarness {
  checkedSource(source) {
    if (!allowedSources.includes(source) || !this.tracked.has(source)) throw Error(`missing allowed session source: ${source}`);
    const original = readFileSync(join(this.root, source), 'utf8');
    if (hash(original) !== this.tracked.get(source)) throw Error(`session source hash mismatch: ${source}`);
    this.loadedFiles.set(source, { path: source, sha256: this.tracked.get(source) });
    return original;
  }
  module(file) {
    const path = relative(this.root, file);
    if (allowedSources.includes(path)) this.checkedSource(path);
    return super.module(file);
  }
  throwing(importer, specifier, name) {
    const entry = { kind: 'execution-service', importer, specifier, export: name };
    return `function(){globalThis.__captureAudit.push(${JSON.stringify(entry)});throw Error(${JSON.stringify(`deferred execution-only binding: ${specifier}:${name}`)});}`;
  }
  stub(importer, specifier, exports) {
    if (!this.stubs.some(item => item.importer === importer && item.specifier === specifier)) this.stubs.push({ importer, specifier, exports });
    const code = exports.map(name => name === 'default'
      ? `export default ${this.throwing(importer, specifier, name)};`
      : name === 'Value.Check' ? `export const Value={Check:${this.throwing(importer, specifier, name)}};`
        : `export const ${name}=${this.throwing(importer, specifier, name)};`).join('\n');
    return this.synthetic(`capture:session-stub:${importer}:${specifier}`, code);
  }
  projection(importer, specifier, source, exports, kind, regions, wrap, extra = {}) {
    const original = this.checkedSource(source);
    const selected = selectionsFor(original, regions);
    const generatedCode = wrap(selected.map(item => item.selected));
    const executable = stripTypeScriptTypes(generatedCode, { mode: 'transform', sourceMap: false });
    if (!this.projections.some(item => item.importer === importer && item.specifier === specifier)) this.projections.push({
      importer, specifier, source, sourceSha256: this.tracked.get(source), exports, kind,
      selections: selected.map(item => item.selection), generatedCode, generatedSha256: hash(generatedCode), executableSha256: hash(executable), ...extra,
    });
    return this.synthetic(join(this.root, `${source}.capture-${kind}-${importer.replaceAll('/', '_')}.ts`), executable);
  }
  import(specifier, importer) {
    // Projection identifiers preserve source directories, so relative pure imports
    // keep the upstream module's resolution rules.
    const rawOwner = relative(this.root, importer);
    const owner = rawOwner.includes('.capture-') ? rawOwner.slice(0, rawOwner.indexOf('.capture-')) : rawOwner;
    const alias = aliases.find(([path, name]) => path === owner && specifier === `@openclaw/normalization-core/${name}`);
    if (alias) {
      const source = normalization + alias[1] + '.ts';
      const mod = this.projection(owner, specifier, source, alias[2], 'session-normalization-export', [], () =>
        `export {${alias[2].join(',')}} from ${JSON.stringify(`capture:session-source:${source}`)};`);
      this.normalizationTargets ??= new Map();
      this.normalizationTargets.set(mod.identifier, source);
      return mod;
    }
    const normalizationSource = this.normalizationTargets?.get(importer);
    if (normalizationSource && specifier === `capture:session-source:${normalizationSource}`) {
      return this.module(join(this.root, normalizationSource));
    }
    if (SESSION_FACTORY_SOURCES.includes(owner) && specifier === './gateway-caller-context.js') {
      const deferred = owner === list ? ['captureGatewayToolCallerAssertion', 'resolveGatewayToolOperatorSelection']
        : owner === status ? ['resolveGatewayToolOperatorSelection'] : [];
      return this.projection(owner, specifier, wrapper, ['wrapGatewayPersonalToolExecution', ...deferred], 'session-execution-wrapper', [[718, 736]], parts =>
        wrapperBindings.map(name => `${deferred.includes(name) ? 'export ' : ''}const ${name}=${this.throwing(owner, specifier, name)};`).join('\n') + '\n'
        + deferred.filter(name => !wrapperBindings.includes(name)).map(name => `export const ${name}=${this.throwing(owner, specifier, name)};`).join('\n') + '\n' + parts[0],
      { deferredBindings: wrapperBindings, executionOnlyExports: deferred });
    }
    if (SESSION_FACTORY_SOURCES.includes(owner) && specifier === './sessions-helpers.js') {
      const exports = helperExecutionExports[owner];
      return this.projection(owner, specifier, helpers, ['SESSION_LIST_KINDS', 'SessionListRowSchema', ...exports], 'session-list-row-schema', [[37, 97]], parts =>
        'import {Type} from "typebox";\nimport {SessionCreatedActorSchema,SessionRowSchema} from "../../../packages/gateway-protocol/src/schema/sessions-row.js";\nimport {stringEnum} from "../schema/typebox.js";\n'
        + parts[0] + '\n' + exports.map(name => `export const ${name}=${this.throwing(owner, specifier, name)};`).join('\n'),
      { executionOnlyExports: exports });
    }
    const rule = serviceRules.find(([path, name]) => path === owner && name === specifier);
    if (rule) return this.stub(owner, specifier, rule[2]);
    // Only approved whole pure modules reach the inherited resolver; there is no
    // fallback for an unlisted service import.
    return super.import(specifier, importer);
  }
  async metadata(recipe) {
    const { source, tool } = recipe;
    const selectedRegions = tool === 'sessions_list' ? [[55, 111], [134, 142]]
      : tool === 'sessions_history' ? [[53, 99], [342, 347]] : [[204, 209]];
    const prelude = tool === 'sessions_list'
      ? 'import {Type} from "typebox";\nimport {SessionsListParamsSchema} from "../../../packages/gateway-protocol/src/schema/sessions-list.js";\nimport {requesterProfileSchema,stringEnum} from "../schema/typebox.js";\nimport {describeSessionsListTool,SESSIONS_LIST_TOOL_DISPLAY_SUMMARY,SESSION_LINK_RULE_DESCRIPTION} from "../tool-description-presets.js";\nimport {SESSION_LIST_KINDS,SessionListRowSchema} from "./sessions-helpers.js";\n'
      : tool === 'sessions_history'
        ? 'import {Type} from "typebox";\nimport {ChatHistoryParamsSchema,ChatPendingInputsPageSchema} from "../../../packages/gateway-protocol/src/schema/logs-chat.js";\nimport {requesterProfileSchema} from "../schema/typebox.js";\nimport {describeSessionsHistoryTool,SESSIONS_HISTORY_TOOL_DISPLAY_SUMMARY,SESSION_LINK_RULE_DESCRIPTION} from "../tool-description-presets.js";\n'
        : 'import {SessionStatusToolSchema,SessionStatusOutputSchema} from "./session-status-tool.schema.js";\nimport {describeSessionStatusTool,SESSION_STATUS_TOOL_DISPLAY_SUMMARY} from "../tool-description-presets.js";\n';
    const mod = this.projection(source, 'capture:session-metadata', source, ['captureMetadata'], 'session-metadata-region', selectedRegions, parts =>
      prelude + (parts.length === 2 ? parts[0] + '\n' : '') + 'export function captureMetadata(opts={}){return {\n' + parts.at(-1) + '\n};}\n');
    await mod.link((specifier, importer) => this.import(specifier, importer.identifier));
    await mod.evaluate({ timeout: 200 });
    this.context.__metadata = mod.namespace;
    return this.call(`__metadata.captureMetadata(${JSON.stringify(recipe.args[0])})`);
  }
}

function evidence(harness) {
  return { attemptedCalls: harness.call('globalThis.__captureAudit'),
    loadedFiles: [...harness.loadedFiles.values()].sort((a, b) => a.path.localeCompare(b.path)),
    projections: harness.projections, stubs: harness.stubs, configBindings: [],
    typebox: { version: harness.typeboxVersion ?? null, files: [...harness.dependencies.values()].sort((a, b) => a.path.localeCompare(b.path)) } };
}

function recipes() {
  return [
    { tool: 'sessions_list', source: list, export: 'createSessionsListTool', variants: [
      ['default', {}], ['linked', { sessionLinkBase: 'https://reference.example/sessions' }],
      ['without-active-only', { supportsActiveOnly: false }], ['without-active-only-linked', { supportsActiveOnly: false, sessionLinkBase: 'https://reference.example/sessions' }],
    ] },
    { tool: 'sessions_history', source: history, export: 'createSessionsHistoryTool', variants: [
      ['default', {}], ['linked', { sessionLinkBase: 'https://reference.example/sessions' }],
    ] },
    { tool: 'session_status', source: status, export: 'createSessionStatusTool', variants: [['default', {}]] },
  ].flatMap(({ variants, ...tool }) => [
    ...variants.map(([variant, options]) => ({ ...tool, id: `session/${tool.tool}/${variant}`, args: [options] })),
    ...representativeContexts().map(context => ({ ...tool, id: `session/${tool.tool}/context/${context.id}`, args: [context.options], representativeContext: context })),
  ]).map(recipe => ({ ...recipe, allowedSources }));
}

export async function captureSessionFactories(root, sourceFiles) {
  const tracked = new Map(sourceFiles.filter(file => file.kind !== 'symlink').map(file => [file.path, file.sha256]));
  const rows = [];
  for (const recipe of recipes()) {
    const harness = new SessionFactoryHarness(root, tracked, recipe);
    const row = { id: recipe.id, referenceTool: recipe.tool, source: recipe.source, sourceSha256: tracked.get(recipe.source) ?? null,
      export: recipe.export, args: recipe.args, context: `recipe/${recipe.id}`, evidence: 'factory-return',
      eligibility: { status: 'unresolved', reason: 'constructor options do not establish runtime assembly or eligibility' }, registration: { status: 'unresolved' },
      platformCapabilities: ['TextEncoder'], executeInvoked: false,
      executionBoundary: { toolExecuteInvoked: false, wrapperBodyInvoked: false, lazyLoaderInvoked: false, dynamicImportsInvoked: false } };
    if (recipe.representativeContext) row.representativeContext = recipe.representativeContext;
    try {
      await harness.load(recipe.source);
      row.descriptor = harness.call(`(()=>{const t=__exports[${JSON.stringify(recipe.export)}](${JSON.stringify(recipe.args[0])});return {name:t.name,label:t.label,displaySummary:t.displaySummary,description:t.description,parameters:t.parameters,outputSchema:t.outputSchema,executeObserved:typeof t.execute==='function'};})()`);
      if (row.descriptor.name !== recipe.tool || !row.descriptor.executeObserved) throw Error('unexpected session factory descriptor');
      row.schema = describeSchema(row.descriptor.parameters);
      row.outputSchema = describeSchema(row.descriptor.outputSchema);
      const comparison = new SessionFactoryHarness(root, tracked, recipe);
      const metadata = await comparison.metadata(recipe);
      row.definitionComparison = { kind: 'source-metadata-region', freshVm: true, source: recipe.source, sourceSha256: tracked.get(recipe.source),
        selector: 'metadata', syntheticExport: 'captureMetadata', args: recipe.args, metadata, executeInvoked: false, ...evidence(comparison) };
      const { executeObserved, ...actual } = row.descriptor;
      row.descriptorMatch = JSON.stringify(ordered(actual)) === JSON.stringify(ordered(metadata));
      if (!row.descriptorMatch) throw Error('actual session factory metadata differs from exact source metadata region');
      if (row.definitionComparison.attemptedCalls.length) throw Error('metadata comparison called an execution-only binding');
      row.status = 'captured';
    } catch (error) {
      row.status = 'unresolved';
      row.reason = String(error.message).replaceAll(root, '<source>').replace(/\s+/g, ' ').slice(0, 400);
    }
    Object.assign(row, evidence(harness));
    if (row.attemptedCalls.length) { row.status = 'unresolved'; row.reason = 'construction called an execution-only binding'; }
    rows.push(row);
  }
  return rows;
}
