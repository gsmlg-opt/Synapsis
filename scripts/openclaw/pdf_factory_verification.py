"""Independent PDF construction provenance; no PDF execution/readiness claims.

Reconstruct source selections and portable wrappers here. The positive Node
suite recomputes stripTypeScriptTypes executable digests with Node 24.22.1.
"""
import hashlib
import json
import re

TOOLS = 'src/agents/tools/'
NORMALIZATION = 'packages/normalization-core/src/'
PDF_FACTORY_SOURCE = TOOLS + 'pdf-tool.ts'
PDF_HELPERS = TOOLS + 'pdf-tool.helpers.ts'
IMAGE_HELPERS = TOOLS + 'image-tool.helpers.ts'
MODEL_HELPERS = TOOLS + 'model-config.helpers.ts'
MODEL_INPUT = 'src/config/model-input.ts'
SCHEMA_SOURCES = {'src/agents/schema/typebox.ts', 'src/agents/schema/string-enum.ts',
                  'src/infra/outbound/channel-target.ts'}
NORMALIZATION_SOURCES = {NORMALIZATION + name + '.ts' for name in ['number-coercion', 'record-coerce', 'string-coerce']}
ALLOWED_SOURCES = {PDF_FACTORY_SOURCE, PDF_HELPERS, IMAGE_HELPERS, MODEL_HELPERS, MODEL_INPUT} | SCHEMA_SOURCES | NORMALIZATION_SOURCES
ALIASES = {
    (PDF_FACTORY_SOURCE, 'number-coercion'): ['asFiniteNumber'],
    (PDF_FACTORY_SOURCE, 'record-coerce'): ['asRecord'],
    (PDF_FACTORY_SOURCE, 'string-coerce'): ['normalizeOptionalString'],
    (MODEL_INPUT, 'number-coercion'): ['asPositiveFiniteNumber'],
    (MODEL_INPUT, 'string-coerce'): ['resolvePrimaryStringValue'],
}
STUB_MODULES = {
    '@openclaw/media-core/mime', '../../gateway/operator-invocation-authority.js',
    '../../media-understanding/defaults.js', '../../media/document-extraction-metadata.js',
    '../../media/media-reference.js', '../../media/pdf-extract.js', '../../media/web-media.js',
    '../../shared/async-work-resources.js', '../../shared/async-work-scope.js', '../admitted-run-context.js',
    '../embedded-agent-runner/model.js', '../embedded-agent-runner/run/abortable.js', '../model-auth.js',
    '../model-fallback-image.js', '../prepared-model-runtime.js', '../prepared-model-runtime.resources.js',
    '../provider-request-config.js', '../sandbox-media-paths.js', '../simple-completion-execution.js',
    '../simple-completion-runtime.js', './common.js', './media-tool-shared.js', './pdf-native-providers.js',
    './pdf-tool.model-config.js',
}
MODEL_PRELUDE = 'import {resolveAgentModelFallbackValues,resolveAgentModelPrimaryValue,resolveAgentModelTimeoutMsValue} from "../../config/model-input.js";\n'
INPUT_PRELUDE = 'import {asPositiveFiniteNumber} from "@openclaw/normalization-core/number-coercion";\nimport {resolvePrimaryStringValue} from "@openclaw/normalization-core/string-coerce";\n'
HELPERS = {
    (PDF_FACTORY_SOURCE, './pdf-tool.helpers.js'): (
        PDF_HELPERS, ['coercePdfModelConfig'], [(84, 95)],
        'import {resolveAgentModelFallbackValues,resolveAgentModelPrimaryValue} from "../../config/model-input.js";\n',
        ['buildPdfExtractionContext', 'coercePdfAssistantText', 'parsePageRange', 'resolvePdfInputs', 'resolvePdfToolMaxTokens']),
    (PDF_FACTORY_SOURCE, './image-tool.helpers.js'): (
        IMAGE_HELPERS, ['coerceImageModelConfig'], [(108, 110)],
        'import {coerceToolModelConfig} from "./model-config.helpers.js";\n', []),
    (PDF_FACTORY_SOURCE, './model-config.helpers.js'): (
        MODEL_HELPERS, ['hasToolModelConfig', 'coerceToolModelConfig'], [(62, 66), (403, 412)], MODEL_PRELUDE,
        ['applyAgentDefaultModelConfig', 'prepareToolAuthProfileStore']),
    (IMAGE_HELPERS, './model-config.helpers.js'): (
        MODEL_HELPERS, ['hasToolModelConfig', 'coerceToolModelConfig'], [(62, 66), (403, 412)], MODEL_PRELUDE, []),
    **{(owner, '../../config/model-input.js'): (
        MODEL_INPUT, ['resolveAgentModelPrimaryValue', 'resolveAgentModelFallbackValues', 'resolveAgentModelTimeoutMsValue'],
        [(23, 33), (53, 59)], INPUT_PRELUDE, []) for owner in [PDF_HELPERS, MODEL_HELPERS]},
}
BOUNDARY = {'toolExecuteInvoked': False, 'pdfExecutionInvoked': False, 'resourceAcquisitionInvoked': False,
            'modelReadinessInvoked': False, 'authInvoked': False, 'dynamicImportsInvoked': False}
LIMITS = {
    'constructorCases': 'agentDir-present; no explicit pdfModel/imageModel',
    'excluded': ['absent-agentDir', 'null-return', 'throwing-constructor', 'explicit-model-config', 'auth-readiness'],
    'unexecuted': ['pdf-loading', 'extraction', 'native-provider', 'model-fallback', 'resource-lifecycle',
                   'tool-execute', 'runtime-assembly', 'registration'],
}


def _hash(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def _throwing(importer, specifier, name):
    entry = {'kind': 'execution-service', 'importer': importer, 'specifier': specifier, 'export': name}
    return ('function(){globalThis.__captureAudit.push(' + _json(entry) + ');throw Error('
            + _json(f'deferred execution-only binding: {specifier}:{name}') + ');}')


def _source(fixtures, source, require, safe_path):
    require(source in ALLOWED_SOURCES, 'unsupported PDF source: ' + str(source))
    file = safe_path(fixtures / 'sources', source)
    require(file.is_file(), 'missing PDF source snapshot: ' + source)
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


def verify_pdf_projection(projection, fixtures, require, safe_path):
    source, owner, specifier = (projection.get(key) for key in ['source', 'importer', 'specifier'])
    original = _source(fixtures, source, require, safe_path)
    require(projection.get('sourceSha256') == _hash(original), 'PDF projection source hash mismatch')
    base = {'importer', 'specifier', 'source', 'sourceSha256', 'exports', 'kind', 'selections',
            'generatedCode', 'generatedSha256', 'executableSha256'}
    extra = set()
    kind = projection.get('kind')
    if kind == 'pdf-normalization-export':
        alias = specifier.removeprefix('@openclaw/normalization-core/')
        require(specifier == '@openclaw/normalization-core/' + alias and (owner, alias) in ALIASES,
                'unsupported PDF normalization import')
        exports = ALIASES[(owner, alias)]
        require(source == NORMALIZATION + alias + '.ts' and projection.get('exports') == exports,
                'PDF normalization alias differs from exact source exports')
        regions = []
        generated = 'export {' + ','.join(exports) + '} from ' + _json('capture:pdf-source:' + source) + ';'
    elif kind == 'pdf-pure-helper':
        require((owner, specifier) in HELPERS, 'unsupported PDF helper importer')
        expected_source, pure, regions, prelude, deferred = HELPERS[(owner, specifier)]
        require(source == expected_source and projection.get('exports') == pure + deferred
                and projection.get('pureExports') == pure and projection.get('executionOnlyExports') == deferred,
                'PDF helpers must preserve exact pure exports and audited deferred bindings')
        extra = {'pureExports', 'executionOnlyExports'}
        generated = (prelude + '\n'.join(part for _, part in _selections(original, regions)) + '\n'
                     + '\n'.join('export const ' + name + '=' + _throwing(owner, specifier, name) + ';' for name in deferred))
    elif kind == 'pdf-metadata-region':
        require(source == owner == PDF_FACTORY_SOURCE and specifier == 'capture:pdf-metadata'
                and projection.get('exports') == ['captureMetadata'], 'unsupported PDF metadata selection')
        regions = [(78, 94), (145, 146), (557, 560)]
        parts = [part for _, part in _selections(original, regions)]
        generated = ('import {Type} from "typebox";\nimport {optionalFiniteNumberSchema} from "../schema/typebox.js";\n'
                     + parts[0] + '\nexport function captureMetadata(options={}){\n' + parts[1]
                     + '\nreturn {\n' + parts[2] + '\n};}\n')
    else:
        require(False, 'unsupported PDF projection kind: ' + str(kind))
    require(set(projection) == base | extra, 'unsupported PDF projection fields')
    require(projection.get('selections') == [selection for selection, _ in _selections(original, regions)],
            'PDF source byte/line selection differs from exact pinned region')
    require(projection.get('generatedCode') == generated and projection.get('generatedSha256') == _hash(generated),
            'PDF wrapper differs from source regions and explicit audited bindings')
    require(isinstance(projection.get('executableSha256'), str)
            and re.fullmatch('[a-f0-9]{64}', projection['executableSha256']) is not None,
            'invalid PDF executable digest; positive Node suite recomputes actual transformer bytes')


def expected_pdf_recipes():
    """Reconstruct the full matrix without trusting capture contexts or producer recipes."""
    expected = {
        'pdf/factory/default': ({'agentDir': '/reference/agent'}, None),
        'pdf/factory/configured-defaults': ({'agentDir': '/reference/agent', 'config': {
            'agents': {'defaults': {'pdfMaxMb': 24, 'pdfMaxPages': 32}}}}, None),
    }
    for role in ['primary', 'child', 'scheduled']:
        for profile in ['minimal', 'coding', 'messaging', 'full']:
            for configured in [False, True]:
                context_id = f'{role}/{profile}/' + ('configured' if configured else 'unconfigured')
                options = {'config': {'tools': {'profile': profile}, 'plugins': {'enabled': configured},
                                      'browser': {'enabled': configured}},
                           'agentSessionKey': ('agent:reference:subagent:fixture' if role == 'child' else
                                               'agent:reference:cron:fixture' if role == 'scheduled' else 'agent:reference:main'),
                           'sessionKey': 'agent:reference:main', 'agentId': 'reference',
                           'workspaceDir': '/reference/workspace', 'isSubagent': role == 'child',
                           'sandboxed': role == 'child', 'isScheduled': role == 'scheduled',
                           'modelSupportsVision': configured, 'hasConnectedClient': configured, 'allowDeviceTools': configured}
                context = {'id': context_id, 'role': role, 'profile': profile, 'configured': configured, 'options': options}
                expected['pdf/factory/context/' + context_id] = ({**options, 'agentDir': '/reference/agent'}, context)
    return expected


def verify_pdf_matrix(capture, require):
    rows = [row for row in capture.get('recipes', []) if row.get('source') == PDF_FACTORY_SOURCE or str(row.get('id', '')).startswith('pdf/')]
    expected = expected_pdf_recipes()
    require(len(rows) == 26 and {row.get('id') for row in rows} == set(expected),
            'PDF construction matrix differs from 26 ordinary positive cases')
    for row in rows:
        args, context = expected[row['id']]
        require(row.get('source') == PDF_FACTORY_SOURCE and row.get('args') == [args]
                and row.get('representativeContext') == context and row.get('status') == 'captured',
                'PDF constructor inputs/context differ from independent positive matrix')
        if context is not None:
            require(context in capture.get('contexts', []), 'PDF context must retain the recorded shared context')


def _expected_stubs(raw, require):
    result = {}
    for match in re.finditer(r'^import (?!type\b)([\s\S]*?) from "([^"]+)";', raw.decode(), re.MULTILINE):
        clause, specifier = match.groups()
        if specifier in STUB_MODULES:
            require(clause.startswith('{') and clause.endswith('}'), 'unsupported PDF service import clause')
            result[(PDF_FACTORY_SOURCE, specifier)] = [item.strip().split(' as ')[0] for item in clause[1:-1].split(',')
                                                     if item.strip() and not item.strip().startswith('type ')]
    require({specifier for _, specifier in result} == STUB_MODULES, 'PDF execution import audit differs from pinned source')
    return result


def _verify_evidence(evidence, recipe, capture, tracked, fixtures, require, safe_path, comparison=False):
    require(evidence.get('attemptedCalls') == [] and evidence.get('configBindings') == [],
            'PDF construction must not invoke execution services or synthetic readiness/config bindings')
    files = evidence.get('loadedFiles', [])
    paths = [item.get('path') for item in files]
    expected_paths = {PDF_FACTORY_SOURCE} | SCHEMA_SOURCES
    if not comparison:
        expected_paths |= {PDF_HELPERS, IMAGE_HELPERS, MODEL_HELPERS, MODEL_INPUT} | NORMALIZATION_SOURCES
    require(len(paths) == len(set(paths)) and set(paths) == expected_paths, 'PDF loaded source boundary differs from exact audited set')
    for item in files:
        require(set(item) == {'path', 'sha256'}
                and item['sha256'] == tracked.get(item['path']) == _hash(_source(fixtures, item['path'], require, safe_path)),
                'PDF loaded source differs from pinned snapshot')
    projections = evidence.get('projections', [])
    keys = [(item.get('importer'), item.get('specifier')) for item in projections]
    expected_keys = {(PDF_FACTORY_SOURCE, 'capture:pdf-metadata')} if comparison else (
        set(HELPERS) | {(owner, '@openclaw/normalization-core/' + alias) for owner, alias in ALIASES})
    require(len(keys) == len(set(keys)) and set(keys) == expected_keys, 'PDF helper/metadata projection evidence missing or unexpected')
    for projection in projections:
        verify_pdf_projection(projection, fixtures, require, safe_path)
        require(projection['source'] in paths, 'PDF projection source missing from loaded evidence')
    expected_stubs = {} if comparison else _expected_stubs(_source(fixtures, PDF_FACTORY_SOURCE, require, safe_path), require)
    actual_stubs = {}
    for stub in evidence.get('stubs', []):
        require(set(stub) == {'importer', 'specifier', 'exports'}, 'unsupported PDF stub fields')
        key = (stub['importer'], stub['specifier'])
        require(key not in actual_stubs, 'duplicate PDF execution import stub')
        actual_stubs[key] = stub['exports']
    require(actual_stubs == expected_stubs, 'PDF stubs differ from explicit original execution imports')
    dependency = evidence.get('typebox', {})
    require(dependency.get('version') == '1.3.37' and dependency.get('files'), 'missing pinned PDF TypeBox provenance')
    dependency_paths = set()
    aggregate = {item['path']: item['sha256'] for item in capture.get('dependencies', [])}
    factory_dependencies = {item['path']: item['sha256'] for item in recipe.get('typebox', {}).get('files', [])}
    for item in dependency['files']:
        path = item.get('path', '')
        require(set(item) == {'path', 'sha256'} and path.startswith('typebox/') and path not in dependency_paths
                and all(part not in ('..', '.') for part in path.split('/'))
                and re.fullmatch('[a-f0-9]{64}', item.get('sha256', '')) is not None,
                'invalid PDF TypeBox source provenance')
        dependency_paths.add(path)
        require(aggregate.get(path) == item['sha256'], 'PDF TypeBox digest differs from aggregate source provenance')
        if comparison:
            require(factory_dependencies.get(path) == item['sha256'], 'PDF comparison TypeBox source differs from factory')
    require('typebox/package.json' in dependency_paths, 'PDF TypeBox provenance omits package metadata')


def verify_pdf_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path):
    require(recipe.get('source') == PDF_FACTORY_SOURCE and recipe.get('referenceTool') == 'pdf'
            and recipe.get('export') == 'createPdfTool' and recipe.get('evidence') == 'factory-return'
            and recipe.get('executeInvoked') is False and recipe.get('platformCapabilities') == ['TextEncoder'],
            'unsupported actual PDF factory evidence')
    require(recipe.get('context') == 'recipe/' + recipe['id'] and recipe.get('executionBoundary') == BOUNDARY
            and recipe.get('limits') == LIMITS, 'PDF construction must preserve explicit deferred execution/readiness boundaries')
    require(recipe.get('eligibility', {}).get('status') == 'unresolved' and recipe.get('registration', {}).get('status') == 'unresolved',
            'PDF construction does not prove eligibility, assembly or registration')
    descriptor = recipe.get('descriptor', {})
    require(set(descriptor) == {'name', 'label', 'description', 'parameters', 'executeObserved'}
            and descriptor.get('name') == 'pdf' and descriptor.get('label') == 'PDF' and descriptor.get('executeObserved') is True
            and isinstance(descriptor.get('description'), str) and descriptor['description'], 'incomplete actual PDF descriptor')
    comparison = recipe.get('definitionComparison', {})
    require(comparison.get('kind') == 'source-metadata-region' and comparison.get('freshVm') is True
            and comparison.get('source') == PDF_FACTORY_SOURCE and comparison.get('sourceSha256') == tracked.get(PDF_FACTORY_SOURCE)
            and comparison.get('syntheticExport') == 'captureMetadata' and 'export' not in comparison
            and comparison.get('selector') == 'metadata' and comparison.get('args') == recipe.get('args')
            and comparison.get('executeInvoked') is False, 'PDF comparison must use exact source metadata regions in a fresh VM')
    require(recipe.get('descriptorMatch') is True
            and comparison.get('metadata') == {key: value for key, value in descriptor.items() if key != 'executeObserved'},
            'PDF descriptor differs from independent source metadata region')
    schema = recipe.get('schema', {})
    require(schema.get('parameters') == descriptor['parameters']
            and json.loads(schema.get('schemaJson', 'null')) == descriptor['parameters']
            and _hash(schema['schemaJson']) == schema.get('schemaSha256')
            and schema.get('actions') == [] and schema.get('actionlessBranches') == 1,
            'PDF schema metadata serialization differs from actual descriptor')
    _verify_evidence(recipe, recipe, capture, tracked, fixtures, require, safe_path)
    _verify_evidence(comparison, recipe, capture, tracked, fixtures, require, safe_path, comparison=True)
