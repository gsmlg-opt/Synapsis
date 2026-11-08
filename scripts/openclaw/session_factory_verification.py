"""Source/metadata provenance for construction-only pinned session recipes.

Python checks source selections and generated wrapper bytes. It validates the
recorded transformed executable hash format; the Node metadata suite recomputes
that hash with the capture runtime's real TypeScript transformer.
"""
import hashlib
import json
import re


TOOLS = 'src/agents/tools/'
PROTOCOL = 'packages/gateway-protocol/src/'
NORMALIZATION = 'packages/normalization-core/src/'
LIST = TOOLS + 'sessions-list-tool.ts'
HISTORY = TOOLS + 'sessions-history-tool.ts'
STATUS = TOOLS + 'session-status-tool.ts'
SESSION_FACTORY_SOURCES = {LIST, HISTORY, STATUS}
FACTORIES = {
    LIST: ('sessions_list', 'createSessionsListTool'),
    HISTORY: ('sessions_history', 'createSessionsHistoryTool'),
    STATUS: ('session_status', 'createSessionStatusTool'),
}
WRAPPER = TOOLS + 'gateway-caller-context.ts'
HELPERS = TOOLS + 'sessions-helpers.ts'
WRAPPER_BINDINGS = ['withGatewayPersonalToolUser', 'readToolStringParam', 'asNonArrayRecord',
                    'getGatewayToolCallerIdentity', 'resolveGatewayToolOperatorSelection']
HELPER_EXPORTS = {
    LIST: ['createSessionVisibilityRowChecker', 'classifySessionListKind', 'deriveChannel',
           'resolveDisplaySessionKey', 'resolveInternalSessionKey', 'resolveSessionToolContext'],
    HISTORY: ['createSessionVisibilityRowChecker', 'formatSessionToolAccessDenial', 'isSessionToolMainAlias',
              'resolveSessionReference', 'resolveSessionToolAccess', 'resolveSessionToolContext',
              'resolveVisibleSessionReference', 'shouldResolveSessionIdInput'],
    STATUS: ['formatSessionToolAccessDenial', 'resolveCurrentSessionClientAlias', 'resolveSessionReference',
             'resolveSessionToolAccess', 'resolveSessionToolContext', 'resolveVisibleSessionReference',
             'shouldResolveSessionIdInput'],
}
PROTOCOL_FILES = {PROTOCOL + path + '.ts' for path in [
    'chat-work-context', 'client-info', 'human-mention-limits', 'secret-ref-contract', 'session-communication', 'session-limits',
    'schema/chat-history-constants', 'schema/closed-object', 'schema/human-mentions', 'schema/logs-chat', 'schema/primitives',
    'schema/session-classification', 'schema/session-participant', 'schema/sessions-activity-summary',
    'schema/sessions-communication', 'schema/sessions-list', 'schema/sessions-provider-review', 'schema/sessions-row',
    'schema/sessions-sharing-values', 'schema/sessions-sharing-constants', 'schema/string-literal-union', 'schema/user-profile-constants',
]}
ALLOWED_SOURCES = SESSION_FACTORY_SOURCES | PROTOCOL_FILES | {
    WRAPPER, HELPERS, 'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts',
    'src/agents/tool-description-presets.ts', 'src/infra/outbound/channel-target.ts',
    TOOLS + 'session-status-tool.schema.ts', 'src/shared/lazy-promise.ts',
    NORMALIZATION + 'string-coerce.ts', NORMALIZATION + 'record-coerce.ts', NORMALIZATION + 'utf16-slice.ts',
}
ALIASES = {
    (LIST, 'string-coerce'): ['readStringValue'],
    (STATUS, 'string-coerce'): ['readStringValue'],
    (HISTORY, 'record-coerce'): ['asOptionalRecord'],
    (PROTOCOL + 'client-info.ts', 'string-coerce'): ['normalizeOptionalLowercaseString'],
    (PROTOCOL + 'schema/logs-chat.ts', 'record-coerce'): ['asOptionalRecord'],
    (PROTOCOL + 'schema/logs-chat.ts', 'utf16-slice'): ['truncateUtf16Safe'],
}
STUB_MODULES = {
    LIST: ['p-map', 'typebox/value', '../../gateway/session-utils-core.js', '../../routing/session-key.js',
           '../../sessions/session-state-events.js', '../agent-scope.js', './chat-history-text.js', './common.js',
           './in-process-gateway.js', './scoped-session-access.js'],
    HISTORY: ['@openclaw/normalization-core/number-coercion', '../../config/sessions/session-store-owner.js',
              '../../gateway/session-transcript-readers.js', '../../infra/json-utf8-bytes.js', '../../routing/session-key.js',
              '../../utils.js', '../agent-scope.js', './chat-history-text.js', './common.js', './in-process-gateway.js',
              './scoped-session-access.js'],
    STATUS: ['../../config/sessions.js', '../../routing/session-key.js', '../../sessions/session-state-events.js',
             '../../utils/delivery-context.read.js', '../../utils/delivery-context.shared.js', '../../utils/message-channel.js',
             '../agent-scope.js', '../model-selection.js', '../model-thinking-default.js', '../prepared-model-catalog.js',
             '../session-model-ref.js', './common.js', './in-process-gateway.js', './scoped-session-access.js',
             './session-status-capabilities.js', './session-status-model.js', './session-status-session-resolve.js',
             './session-status-state-changes.js'],
}
REGIONS = {LIST: [(55, 111), (134, 142)], HISTORY: [(53, 99), (342, 347)], STATUS: [(204, 209)]}
PRELUDES = {
    LIST: 'import {Type} from "typebox";\nimport {SessionsListParamsSchema} from "../../../packages/gateway-protocol/src/schema/sessions-list.js";\nimport {requesterProfileSchema,stringEnum} from "../schema/typebox.js";\nimport {describeSessionsListTool,SESSIONS_LIST_TOOL_DISPLAY_SUMMARY,SESSION_LINK_RULE_DESCRIPTION} from "../tool-description-presets.js";\nimport {SESSION_LIST_KINDS,SessionListRowSchema} from "./sessions-helpers.js";\n',
    HISTORY: 'import {Type} from "typebox";\nimport {ChatHistoryParamsSchema,ChatPendingInputsPageSchema} from "../../../packages/gateway-protocol/src/schema/logs-chat.js";\nimport {requesterProfileSchema} from "../schema/typebox.js";\nimport {describeSessionsHistoryTool,SESSIONS_HISTORY_TOOL_DISPLAY_SUMMARY,SESSION_LINK_RULE_DESCRIPTION} from "../tool-description-presets.js";\n',
    STATUS: 'import {SessionStatusToolSchema,SessionStatusOutputSchema} from "./session-status-tool.schema.js";\nimport {describeSessionStatusTool,SESSION_STATUS_TOOL_DISPLAY_SUMMARY} from "../tool-description-presets.js";\n',
}
LINK_BASE = 'https://reference.example/sessions'
VARIANTS = {
    'sessions_list': {'default': {}, 'linked': {'sessionLinkBase': LINK_BASE},
                      'without-active-only': {'supportsActiveOnly': False},
                      'without-active-only-linked': {'supportsActiveOnly': False, 'sessionLinkBase': LINK_BASE}},
    'sessions_history': {'default': {}, 'linked': {'sessionLinkBase': LINK_BASE}},
    'session_status': {'default': {}},
}


def _hash(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def _throwing(importer, specifier, name):
    entry = {'kind': 'execution-service', 'importer': importer, 'specifier': specifier, 'export': name}
    return ('function(){globalThis.__captureAudit.push(' + _json(entry) + ');throw Error('
            + _json(f'deferred execution-only binding: {specifier}:{name}') + ');}')


def _source(fixtures, path, require, safe_path):
    require(path in ALLOWED_SOURCES, 'unsupported session source: ' + str(path))
    file = safe_path(fixtures / 'sources', path)
    require(file.is_file(), 'missing session source snapshot: ' + path)
    return file.read_bytes()


def _selections(original, regions):
    lines = original.splitlines(keepends=True)
    result = []
    for start, end in regions:
        before = b''.join(lines[:start - 1])
        selected = b''.join(lines[start - 1:end])
        result.append(({'kind': 'source-lines', 'startLine': start, 'endLine': end,
                        'startByte': len(before), 'endByte': len(before + selected), 'sha256': _hash(selected)},
                       selected.decode()))
    return result


def verify_session_projection(projection, fixtures, require, safe_path):
    source = projection.get('source')
    original = _source(fixtures, source, require, safe_path)
    require(projection.get('sourceSha256') == _hash(original), 'session projection source hash mismatch')
    kind = projection.get('kind')
    owner = projection.get('importer')
    specifier = projection.get('specifier')
    base_keys = {'importer', 'specifier', 'source', 'sourceSha256', 'exports', 'kind', 'selections',
                 'generatedCode', 'generatedSha256', 'executableSha256'}
    extra_keys = set()
    if kind == 'session-normalization-export':
        alias = specifier.removeprefix('@openclaw/normalization-core/')
        require(specifier == '@openclaw/normalization-core/' + alias and (owner, alias) in ALIASES
                and source == NORMALIZATION + alias + '.ts'
                and projection.get('exports') == ALIASES[(owner, alias)], 'unsupported session normalization alias')
        regions = []
        generated = ('export {' + ','.join(ALIASES[(owner, alias)]) + '} from '
                     + _json('capture:session-source:' + source) + ';')
    elif kind == 'session-execution-wrapper':
        extra_keys = {'deferredBindings', 'executionOnlyExports'}
        require(owner in SESSION_FACTORY_SOURCES and source == WRAPPER and specifier == './gateway-caller-context.js',
                'unsupported session wrapper importer/source')
        deferred = ['captureGatewayToolCallerAssertion', 'resolveGatewayToolOperatorSelection'] if owner == LIST else (
            ['resolveGatewayToolOperatorSelection'] if owner == STATUS else [])
        require(projection.get('deferredBindings') == WRAPPER_BINDINGS
                and projection.get('executionOnlyExports') == deferred
                and projection.get('exports') == ['wrapGatewayPersonalToolExecution'] + deferred,
                'session wrapper must retain explicit audited deferred bindings')
        regions = [(718, 736)]
        selected = _selections(original, regions)[0][1]
        generated = '\n'.join(('export ' if name in deferred else '') + 'const ' + name + '='
                              + _throwing(owner, specifier, name) + ';' for name in WRAPPER_BINDINGS)
        generated += '\n' + '\n'.join('export const ' + name + '=' + _throwing(owner, specifier, name) + ';'
                                       for name in deferred if name not in WRAPPER_BINDINGS) + '\n' + selected
    elif kind == 'session-list-row-schema':
        extra_keys = {'executionOnlyExports'}
        require(owner in SESSION_FACTORY_SOURCES and source == HELPERS and specifier == './sessions-helpers.js',
                'unsupported session row-schema projection')
        exports = HELPER_EXPORTS[owner]
        require(projection.get('executionOnlyExports') == exports
                and projection.get('exports') == ['SESSION_LIST_KINDS', 'SessionListRowSchema'] + exports,
                'session helper exports differ from explicit audited bindings')
        regions = [(37, 97)]
        generated = ('import {Type} from "typebox";\nimport {SessionCreatedActorSchema,SessionRowSchema} from "../../../packages/gateway-protocol/src/schema/sessions-row.js";\nimport {stringEnum} from "../schema/typebox.js";\n'
                     + _selections(original, regions)[0][1] + '\n'
                     + '\n'.join('export const ' + name + '=' + _throwing(owner, specifier, name) + ';' for name in exports))
    elif kind == 'session-metadata-region':
        require(owner in SESSION_FACTORY_SOURCES and source == owner and specifier == 'capture:session-metadata'
                and projection.get('exports') == ['captureMetadata'], 'unsupported session metadata source selection')
        regions = REGIONS[source]
        parts = [selected for _, selected in _selections(original, regions)]
        generated = (PRELUDES[source] + (parts[0] + '\n' if len(parts) == 2 else '')
                     + 'export function captureMetadata(opts={}){return {\n' + parts[-1] + '\n};}\n')
    else:
        require(False, 'unsupported session projection kind: ' + str(kind))
    require(set(projection) == base_keys | extra_keys, 'unsupported session projection fields')
    require(projection.get('selections') == [selection for selection, _ in _selections(original, regions)],
            'session source byte selection differs from exact pinned region')
    require(projection.get('generatedCode') == generated and projection.get('generatedSha256') == _hash(generated),
            'session generated wrapper differs from selected source and audited bindings')
    require(isinstance(projection.get('executableSha256'), str)
            and re.fullmatch('[a-f0-9]{64}', projection['executableSha256']) is not None,
            'invalid session transformed executable hash; Node suite recomputes transformer bytes')


def _expected_stubs(source, raw, require):
    imports = {}
    for match in re.finditer(r'^import (?!type\b)([\s\S]*?) from "([^"]+)";', raw.decode(), re.MULTILINE):
        clause, specifier = match.groups()
        if specifier not in STUB_MODULES[source]:
            continue
        if specifier == 'p-map':
            exports = ['default']
        elif specifier == 'typebox/value':
            exports = ['Value.Check']
        else:
            require(clause.startswith('{') and clause.endswith('}'), 'unsupported session service import clause')
            exports = [item.strip().split(' as ')[0] for item in clause[1:-1].split(',')
                       if item.strip() and not item.strip().startswith('type ')]
        imports[(source, specifier)] = exports
    require(set(specifier for _, specifier in imports) == set(STUB_MODULES[source]), 'session service source imports differ from audited module list')
    return imports


def _verify_evidence(evidence, recipe, capture, tracked, fixtures, require, safe_path, comparison=False):
    require(evidence.get('attemptedCalls') == [] and evidence.get('configBindings') == [],
            'session metadata must not invoke execution-only services or config reads')
    files = evidence.get('loadedFiles', [])
    require(isinstance(files, list) and files and len({item['path'] for item in files}) == len(files),
            'session loaded source inventory must be unique and nonempty')
    for item in files:
        original = _source(fixtures, item['path'], require, safe_path)
        require(set(item) == {'path', 'sha256'} and item['sha256'] == tracked.get(item['path']) == _hash(original),
                'session loaded source differs from tracked snapshot')
    source = recipe['source']
    require(any(item['path'] == source for item in files), 'session evidence omits its descriptor source')
    projections = evidence.get('projections', [])
    keys = [(item['importer'], item['specifier']) for item in projections]
    require(len(keys) == len(set(keys)), 'duplicate session projection binding')
    kinds = [item.get('kind') for item in projections]
    require(('session-metadata-region' in kinds) == comparison
            and ('session-execution-wrapper' in kinds) != comparison,
            'session comparison and whole factory evidence must preserve independent boundaries')
    require(('session-list-row-schema' in kinds) == (not comparison or source == LIST),
            'session list row schema projection evidence missing or unexpected')
    for projection in projections:
        verify_session_projection(projection, fixtures, require, safe_path)
        require(any(item['path'] == projection['source'] and item['sha256'] == projection['sourceSha256'] for item in files),
                'session projection source must be present in loaded source evidence')
    expected = {} if comparison else _expected_stubs(source, _source(fixtures, source, require, safe_path), require)
    actual = {}
    for item in evidence.get('stubs', []):
        require(set(item) == {'importer', 'specifier', 'exports'}, 'unsupported session service stub fields')
        key = (item['importer'], item['specifier'])
        require(key not in actual, 'duplicate session service stub')
        actual[key] = item['exports']
    require(actual == expected, 'session service stubs differ from explicit source imports')
    dependency = evidence.get('typebox', {})
    require(dependency.get('version') == '1.3.37' and dependency.get('files'), 'missing pinned session TypeBox provenance')
    paths = set()
    captured_dependencies = {item['path']: item['sha256'] for item in recipe.get('typebox', {}).get('files', [])}
    aggregate_dependencies = {item['path']: item['sha256'] for item in capture.get('dependencies', [])}
    for item in dependency['files']:
        path = item.get('path', '')
        require(set(item) == {'path', 'sha256'} and path.startswith('typebox/') and path not in paths
                and all(part not in ('..', '.') for part in path.split('/'))
                and re.fullmatch('[a-f0-9]{64}', item.get('sha256', '')) is not None,
                'invalid session TypeBox dependency file provenance')
        paths.add(path)
        require(aggregate_dependencies.get(path) == item['sha256'],
                'session TypeBox source differs from aggregate capture dependency provenance')
        if comparison:
            require(captured_dependencies.get(path) == item['sha256'], 'session comparison TypeBox source differs from factory')
    require('typebox/package.json' in paths, 'session TypeBox provenance omits package metadata')


def verify_session_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path):
    source = recipe.get('source')
    require(source in FACTORIES, 'unsupported actual session factory')
    tool, export = FACTORIES[source]
    require(recipe.get('referenceTool') == tool and recipe.get('export') == export
            and recipe.get('evidence') == 'factory-return' and recipe.get('executeInvoked') is False
            and recipe.get('platformCapabilities') == ['TextEncoder'], 'unsupported session factory evidence')
    require(recipe.get('executionBoundary') == {'toolExecuteInvoked': False, 'wrapperBodyInvoked': False,
                                               'lazyLoaderInvoked': False, 'dynamicImportsInvoked': False},
            'session construction evidence must retain deferred-only execution boundary')
    contexts = capture.get('contexts', [])
    expected_contexts = {f'{role}/{profile}/{configured}' for role in ['primary', 'child', 'scheduled']
                         for profile in ['minimal', 'coding', 'messaging', 'full'] for configured in ['unconfigured', 'configured']}
    require({context['id'] for context in contexts} == expected_contexts, 'session representative context matrix differs from 24 cases')
    expected_ids = {f'session/{name}/{variant}' for name, variants in VARIANTS.items() for variant in variants}
    expected_ids |= {f'session/{name}/context/{context}' for name in VARIANTS for context in expected_contexts}
    rows = [row for row in capture.get('recipes', []) if row.get('source') in SESSION_FACTORY_SOURCES]
    require(len(rows) == 79 and {row.get('id') for row in rows} == expected_ids,
            'actual session factory recipe matrix differs from 79 ordinary construction cases')
    require(recipe.get('context') == 'recipe/' + recipe['id'], 'session construction context differs from recipe')
    context = recipe.get('representativeContext')
    if context is not None:
        require(context in contexts and recipe['id'] == f'session/{tool}/context/' + context['id']
                and recipe.get('args') == [context['options']], 'session constructor options differ from recorded context')
    else:
        variant = recipe['id'].removeprefix(f'session/{tool}/')
        require(variant in VARIANTS[tool] and recipe.get('args') == [VARIANTS[tool][variant]],
                'session ordinary variant arguments differ from recorded input')
    require(recipe.get('eligibility', {}).get('status') == 'unresolved'
            and recipe.get('registration', {}).get('status') == 'unresolved',
            'session descriptor construction does not establish assembly or registration')
    descriptor = recipe.get('descriptor', {})
    require(set(descriptor) == {'name', 'label', 'displaySummary', 'description', 'parameters', 'outputSchema', 'executeObserved'}
            and descriptor.get('name') == tool and descriptor.get('executeObserved') is True
            and all(isinstance(descriptor.get(key), str) and descriptor[key] for key in ['label', 'displaySummary', 'description']),
            'session actual descriptor metadata is incomplete')
    comparison = recipe.get('definitionComparison', {})
    require(comparison.get('kind') == 'source-metadata-region' and comparison.get('freshVm') is True
            and comparison.get('source') == source and comparison.get('sourceSha256') == tracked.get(source)
            and comparison.get('syntheticExport') == 'captureMetadata' and 'export' not in comparison
            and comparison.get('selector') == 'metadata' and comparison.get('args') == recipe.get('args')
            and comparison.get('executeInvoked') is False, 'session comparison must use exact source regions in a fresh VM')
    require(recipe.get('descriptorMatch') is True
            and comparison.get('metadata') == {key: value for key, value in descriptor.items() if key != 'executeObserved'},
            'session actual factory descriptor differs from independent metadata region')
    for field, key in [('schema', 'parameters'), ('outputSchema', 'outputSchema')]:
        schema = recipe.get(field, {})
        require(schema.get('parameters') == descriptor.get(key)
                and json.loads(schema.get('schemaJson', 'null')) == descriptor.get(key)
                and _hash(schema['schemaJson']) == schema.get('schemaSha256'),
                'session schema serialization/hash differs from descriptor: ' + field)
    _verify_evidence(recipe, recipe, capture, tracked, fixtures, require, safe_path)
    _verify_evidence(comparison, recipe, capture, tracked, fixtures, require, safe_path, comparison=True)
    if source == STATUS:
        require(any(item['path'] == 'src/shared/lazy-promise.ts' for item in recipe['loadedFiles']),
                'session status must preserve the real deferred lazy-promise implementation')
