"""Independent pinned TTS construction evidence, without invoking the tool.

Reconstruct the ordinary matrix, metadata regions and their TypeBox semantics.
The positive Node suite recomputes actual TypeScript transformation digests.
"""
import hashlib
import json
import re

TTS_FACTORY_SOURCE = 'src/agents/tools/tts-tool.ts'
TRANSFORMATION = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)'
STUB_MODULES = {
    '../../config/config.js': ['getRuntimeConfig'],
    '../../tts/tts.js': ['textToSpeech'],
    './common.js': ['readPositiveIntegerParam', 'readToolStringParam'],
    './tts-tool-result-provenance.js': ['markCoreTtsToolResult'],
}
BOUNDARY = {'toolExecuteInvoked': False, 'transcriptSanitizerInvoked': False,
            'voiceProviderInvoked': False, 'configReadInvoked': False, 'dynamicImportsInvoked': False}
LIMITS = {
    'constructorCases': 'no-args; empty-options; ordinary-agent-options; 24 representative contexts',
    'unexecuted': ['tool-execute', 'transcript-sanitizer', 'voice-provider', 'tts-service', 'runtime-config-read',
                   'readiness', 'eligibility', 'runtime-assembly', 'registration'],
}


def _hash(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def _json(value, sort_keys=False):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=sort_keys)


def _source(fixtures, source, require, safe_path):
    require(source == TTS_FACTORY_SOURCE, 'unsupported TTS source: ' + str(source))
    file = safe_path(fixtures / 'sources', source)
    require(file.is_file(), 'missing TTS source snapshot')
    return file.read_bytes()


def _selections(original):
    lines = original.splitlines(keepends=True)
    selected = []
    for start, end in [(9, 18), (39, 44)]:
        before = b''.join(lines[:start - 1])
        part = b''.join(lines[start - 1:end])
        selected.append(({'kind': 'source-lines', 'startLine': start, 'endLine': end,
                          'startByte': len(before), 'endByte': len(before + part), 'sha256': _hash(part)},
                         part.decode()))
    return selected


def verify_tts_projection(projection, fixtures, require, safe_path):
    require(set(projection) == {'importer', 'specifier', 'source', 'sourceSha256', 'exports', 'kind',
                                'selections', 'generatedCode', 'generatedSha256', 'executableSha256'},
            'unsupported TTS metadata projection fields')
    require(projection.get('kind') == 'tts-metadata-region'
            and projection.get('source') == projection.get('importer') == TTS_FACTORY_SOURCE
            and projection.get('specifier') == 'capture:tts-metadata'
            and projection.get('exports') == ['captureMetadata'], 'unsupported TTS metadata projection')
    original = _source(fixtures, TTS_FACTORY_SOURCE, require, safe_path)
    selected = _selections(original)
    generated = ('import {Type} from "typebox";\n' + selected[0][1]
                 + '\nexport function captureMetadata(){\nreturn {\n' + selected[1][1] + '\n};}\n')
    require(projection['sourceSha256'] == _hash(original)
            and projection['selections'] == [selection for selection, _ in selected],
            'TTS metadata source line/byte selection or digest differs')
    require(projection['generatedCode'] == generated and projection['generatedSha256'] == _hash(generated),
            'TTS metadata wrapper differs from exact source regions')
    require(re.fullmatch('[a-f0-9]{64}', projection.get('executableSha256', '')) is not None,
            'invalid TTS executable digest; positive Node suite recomputes transformer bytes')


def expected_tts_recipes():
    """Reconstruct all arguments independently from producer and recorded contexts."""
    expected = {
        'tts/factory/default': ([], None),
        'tts/factory/empty-options': ([{}], None),
        'tts/factory/agent-options': ([{'config': {'messages': {'tts': {'auto': 'always'}}},
                                       'agentChannel': 'telegram', 'agentId': 'reference',
                                       'agentAccountId': 'reference-account'}], None),
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
                expected['tts/factory/context/' + context_id] = ([options], context)
    return expected


def verify_tts_matrix(capture, require):
    rows = [row for row in capture.get('recipes', []) if row.get('source') == TTS_FACTORY_SOURCE
            or str(row.get('id', '')).startswith('tts/')]
    expected = expected_tts_recipes()
    require(len(rows) == 27 and {row.get('id') for row in rows} == set(expected),
            'TTS construction matrix differs from 27 ordinary positive cases')
    for row in rows:
        args, context = expected[row['id']]
        require(row.get('source') == TTS_FACTORY_SOURCE and row.get('args') == args
                and row.get('representativeContext') == context and row.get('status') == 'captured'
                and row.get('evidence') == 'factory-return',
                'TTS constructor arguments/context/evidence differ from independent ordinary matrix')
        if context is not None:
            require(context in capture.get('contexts', []), 'TTS shared representative context missing')


def _metadata(original, require):
    """Interpret only this pin's exact three-property TypeBox declaration."""
    schema_source, fields_source = [part for _, part in _selections(original)]
    literal = r'("(?:[^"\\]|\\.)*")'
    pattern = (r'const TtsToolSchema = Type\.Object\(\{\s*'
               r'text: Type\.String\(\{ description: ' + literal + r' \}\),\s*'
               r'channel: Type\.Optional\(Type\.String\(\{ description: ' + literal + r' \}\)\),\s*'
               r'timeoutMs: Type\.Optional\(\s*Type\.Integer\(\{\s*description: ' + literal
               + r',\s*minimum: ([0-9]+),\s*\}\),\s*\),\s*\}\);\s*')
    schema = re.fullmatch(pattern, schema_source)
    require(schema is not None, 'TTS source schema differs from independently supported pinned TypeBox declaration')
    text_description, channel_description, timeout_description, minimum = schema.groups()
    fields = re.fullmatch(r'\s*label: ' + literal + r',\s*name: ' + literal
                          + r',\s*displaySummary: ' + literal + r',\s*description:\s*' + literal
                          + r',\s*parameters: TtsToolSchema,\s*', fields_source)
    require(fields is not None, 'TTS source metadata differs from complete pinned field region')
    label, name, summary, description = map(json.loads, fields.groups())
    return {'label': label, 'name': name, 'displaySummary': summary, 'description': description,
            'parameters': {'type': 'object', 'required': ['text'], 'properties': {
                'text': {'type': 'string', 'description': json.loads(text_description)},
                'channel': {'type': 'string', 'description': json.loads(channel_description)},
                'timeoutMs': {'type': 'integer', 'description': json.loads(timeout_description), 'minimum': int(minimum)}}}}


def _expected_stubs(original, require):
    imports = re.findall(r'^import (?!type\b)\{([^}\n]*)\} from "([^"]+)";', original.decode(), re.MULTILINE)
    expected = {}
    for clause, specifier in imports:
        names = [name.strip() for name in clause.split(',')]
        if specifier == 'typebox':
            require(names == ['Type'], 'TTS TypeBox import differs from pinned source')
        else:
            require(specifier in STUB_MODULES and names == STUB_MODULES[specifier],
                    'TTS execution imports differ from exact audited source bindings')
            expected[(TTS_FACTORY_SOURCE, specifier)] = names
    require(len(imports) == 5 and len(expected) == 4, 'TTS import audit differs from exact pinned module set')
    return expected


def _verify_evidence(evidence, recipe, capture, tracked, fixtures, require, safe_path, comparison=False):
    original = _source(fixtures, TTS_FACTORY_SOURCE, require, safe_path)
    require(evidence.get('attemptedCalls') == [] and evidence.get('configBindings') == [],
            'TTS construction called execution services or used synthetic config bindings')
    require(evidence.get('loadedFiles') == [{'path': TTS_FACTORY_SOURCE, 'sha256': _hash(original)}]
            and tracked.get(TTS_FACTORY_SOURCE) == _hash(original), 'TTS loaded source boundary/digest differs')
    projections = evidence.get('projections', [])
    require(len(projections) == int(comparison), 'TTS source projection count differs')
    for projection in projections:
        verify_tts_projection(projection, fixtures, require, safe_path)
    expected_stubs = {} if comparison else _expected_stubs(original, require)
    actual_stubs = {}
    for stub in evidence.get('stubs', []):
        require(set(stub) == {'importer', 'specifier', 'exports'}, 'unsupported TTS stub fields')
        key = (stub['importer'], stub['specifier'])
        require(key not in actual_stubs, 'duplicate TTS execution stub')
        actual_stubs[key] = stub['exports']
    require(actual_stubs == expected_stubs, 'TTS stubs differ from exact execution import set')
    dependency = evidence.get('typebox', {})
    require(set(dependency) == {'version', 'files'} and dependency.get('version') == '1.3.37'
            and dependency.get('files'), 'missing pinned TTS TypeBox provenance')
    aggregate = {item['path']: item['sha256'] for item in capture.get('dependencies', [])}
    actual_dependencies = {}
    for item in dependency['files']:
        path = item.get('path', '')
        require(set(item) == {'path', 'sha256'} and path.startswith('typebox/')
                and all(part not in ('', '.', '..') for part in path.split('/'))
                and path not in actual_dependencies and re.fullmatch('[a-f0-9]{64}', item.get('sha256', '')) is not None,
                'invalid TTS TypeBox source digest evidence')
        require(aggregate.get(path) == item['sha256'], 'TTS TypeBox digest differs from aggregate provenance')
        actual_dependencies[path] = item['sha256']
    require('typebox/package.json' in actual_dependencies, 'TTS TypeBox provenance omits package metadata')
    if comparison:
        factory_dependencies = {item['path']: item['sha256'] for item in recipe['typebox']['files']}
        require(actual_dependencies == factory_dependencies, 'TTS comparison TypeBox source set/digests differ from factory')


def verify_tts_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path):
    require(recipe.get('source') == TTS_FACTORY_SOURCE and recipe.get('referenceTool') == 'tts'
            and recipe.get('export') == 'createTtsTool' and recipe.get('evidence') == 'factory-return'
            and recipe.get('executeInvoked') is False and recipe.get('platformCapabilities') == ['TextEncoder'],
            'unsupported complete TTS factory evidence')
    require(recipe.get('context') == 'recipe/' + recipe['id'] and recipe.get('executionBoundary') == BOUNDARY
            and recipe.get('limits') == LIMITS, 'TTS construction must preserve deferred execution boundaries')
    require(recipe.get('eligibility', {}).get('status') == 'unresolved'
            and recipe.get('registration', {}).get('status') == 'unresolved',
            'TTS construction does not prove eligibility, assembly or registration')
    original = _source(fixtures, TTS_FACTORY_SOURCE, require, safe_path)
    execution = recipe.get('factoryExecution', {})
    require(set(execution) == {'kind', 'sourceSha256', 'transformation', 'executableSha256'}
            and execution.get('kind') == 'complete-source-module'
            and execution.get('sourceSha256') == recipe.get('sourceSha256') == tracked.get(TTS_FACTORY_SOURCE) == _hash(original)
            and execution.get('transformation') == TRANSFORMATION
            and re.fullmatch('[a-f0-9]{64}', execution.get('executableSha256', '')) is not None,
            'TTS complete unchanged source transformation evidence missing')
    expected_metadata = _metadata(original, require)
    require(recipe.get('descriptor') == {**expected_metadata, 'executeObserved': True},
            'TTS full descriptor differs from independently reconstructed pinned metadata/schema')
    comparison = recipe.get('definitionComparison', {})
    require(comparison.get('kind') == 'source-metadata-region' and comparison.get('freshVm') is True
            and comparison.get('source') == TTS_FACTORY_SOURCE and comparison.get('sourceSha256') == _hash(original)
            and comparison.get('syntheticExport') == 'captureMetadata' and 'export' not in comparison
            and comparison.get('selector') == 'metadata' and comparison.get('args') == recipe.get('args')
            and comparison.get('executeInvoked') is False and comparison.get('metadata') == expected_metadata
            and recipe.get('descriptorMatch') is True, 'TTS fresh metadata-region comparison differs')
    parameters = expected_metadata['parameters']
    schema_json = _json(parameters, sort_keys=True)
    require(recipe.get('schema') == {'parameters': parameters, 'actions': [], 'actionlessBranches': 1,
                                     'schemaJson': schema_json, 'schemaSha256': _hash(schema_json)},
            'TTS schema serialization/digest differs from exact source TypeBox semantics')
    require('outputSchema' not in recipe, 'TTS factory has no output schema in this pin')
    _verify_evidence(recipe, recipe, capture, tracked, fixtures, require, safe_path)
    _verify_evidence(comparison, recipe, capture, tracked, fixtures, require, safe_path, comparison=True)
