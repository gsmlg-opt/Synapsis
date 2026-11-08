"""Independent verification of two pinned cron schema-only observations.

Reconstruct source regions and generated wrappers. The dedicated Node suite
recaptures full schemas and recomputes actual TypeScript transformation digests.
"""
import hashlib
import json
import re

INPUT_SOURCE = 'src/agents/tools/cron-tool-schema.ts'
OUTPUT_SOURCE = 'src/agents/tools/cron-tool-output-schema.ts'
PROTOCOL = 'packages/gateway-protocol/src/schema/'
TRANSFORMATION = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)'
BOUNDARY = dict.fromkeys(['factoryInvoked', 'actionsExecuted', 'inputValidationInvoked', 'servicesStarted',
                         'dynamicImportsInvoked', 'eligibilityEstablished', 'registrationInvoked',
                         'runtimeAssemblyInvoked'], False)
BOUNDARY['schemaConstructionOnly'] = True
REGIONS = {
    'src/agents/schema/typebox.ts': ([(50, 53), (69, 81)],
        ['optionalPositiveIntegerSchema', 'optionalNonNegativeIntegerSchema', 'optionalStringEnum', 'stringEnum'],
        'import {Type} from "typebox";\nexport {optionalStringEnum,stringEnum} from "./string-enum.js";\n'),
    'src/gateway/cron-creator-authority-grant.ts': ([(29, 35)], ['CRON_MANAGEMENT_METHODS'], ''),
    PROTOCOL + 'primitives.ts': ([(26, 26)], ['NonEmptyString'], 'import {Type} from "typebox";\n'),
    PROTOCOL + 'logs-chat.ts': ([(128, 157)], ['AgentActivityItemSchema', 'ChatHistoryActivitySchema'],
        'import {Type,type Static} from "typebox";\nimport {closedObject} from "./closed-object.js";\n'
        'import {NonEmptyString} from "./primitives.js";\nimport {stringLiteralUnion} from "./string-literal-union.js";\n'),
    'src/cron/stream-approval-outcome.ts': ([(5, 19)], ['CronStreamApprovalEndedSchema'], 'import {Type} from "typebox";\n'),
}
INPUT_FILES = {
    INPUT_SOURCE, 'src/agents/schema/cached-schema.ts', 'src/infra/map-size.ts',
    'src/agents/schema/string-enum.ts', 'src/agents/schema/typebox.ts',
    'src/agents/tools/automations-tool-name.ts', 'src/agents/tools/gateway-schema.ts',
    'src/gateway/cron-creator-authority-grant.ts',
    'packages/normalization-core/src/number-coercion.ts', 'packages/normalization-core/src/string-coerce.ts',
}
OUTPUT_FILES = {OUTPUT_SOURCE, 'src/agents/schema/tool-output-schema.ts',
    'packages/normalization-core/src/record-coerce.ts', 'src/cron/stream-approval-outcome.ts',
    'packages/gateway-protocol/src/failover-reasons.ts',
    *[PROTOCOL + name for name in ['cron.ts', 'cron-shared.ts', 'closed-object.ts', 'failover-reason.ts',
                                 'string-literal-union.ts', 'primitives.ts', 'logs-chat.ts']]}
# Complete source-generated JSON and real package-file inventories, frozen for
# 488631c / TypeBox 1.3.37 and independently replayed by the dedicated Node suite.
EXPECTED = {
    'cron/schema/default-input': (INPUT_SOURCE, 'createCronToolSchema', 'schema-builder', INPUT_FILES,
        'b087d8dcd413f7213ce117545241e628d4c7436344e612aa10cabe269c04ecd5',
        '5e5caebf0719aa7eec76503248f2799d0a0a66489f602ceabcb8c322e66ebc8e'),
    'cron/schema/complete-output': (OUTPUT_SOURCE, 'CronToolOutputSchema', 'schema-export', OUTPUT_FILES,
        '8195ecebcbc4dfde2f5a1e18b75ac443ee8310e0c5ea0d7a000e9f77250c92d9',
        'ad765126168549eb023a4b376b13367fac535c7166e5d666cce17e96a32bce54'),
}


def _hash(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def _digest(value, require):
    require(isinstance(value, str) and re.fullmatch('[a-f0-9]{64}', value) is not None,
            'invalid cron executable digest; dedicated Node suite recomputes transformer bytes')


def _actions(parameters):
    actions, actionless = set(), 0

    def collect(value):
        if not isinstance(value, dict):
            return
        if isinstance(value.get('const'), str):
            actions.add(value['const'])
        actions.update(item for item in value.get('enum', []) if isinstance(item, str))
        for key in ['anyOf', 'oneOf', 'allOf']:
            for child in value.get(key, []):
                collect(child)

    def visit(value):
        nonlocal actionless
        if not isinstance(value, dict):
            return
        properties = value.get('properties', {})
        if value.get('type') == 'object' and 'action' not in properties:
            actionless += 1
        collect(properties.get('action'))
        for key in ['anyOf', 'oneOf', 'allOf']:
            for child in value.get(key, []):
                visit(child)

    visit(parameters)
    return sorted(actions), actionless


def verify_cron_schema_captures(capture, tracked, fixtures, expected_sources, require, safe_path):
    rows = capture.get('schemaCaptures')
    require(isinstance(rows, list) and len(rows) == 2
            and [row.get('id') for row in rows] == list(EXPECTED), 'cron schema evidence must retain the exact two-row set')
    aggregate = {file['path']: file['sha256'] for file in capture['dependencies']}
    for row in rows:
        source, export, evidence, paths, schema_digest, dependency_digest = EXPECTED[row['id']]
        require(row.get('source') == source and row.get('export') == export
                and row.get('referenceTool') == 'automations' and row.get('args') == []
                and row.get('context') == 'schema/default' and row.get('status') == 'captured'
                and row.get('evidence') == evidence and row.get('executeInvoked') is False
                and row.get('boundaries') == BOUNDARY, 'cron schema arguments or construction-only evidence boundary differs')
        require(set(row) == {'id', 'referenceTool', 'source', 'sourceSha256', 'export', 'args', 'evidence',
                            'context', 'status', 'captureRuntime', 'boundaries', 'executeInvoked', 'schema',
                            'attemptedCalls', 'loadedFiles', 'moduleExecutions', 'projections', 'sourceAliases',
                            'stubs', 'configBindings', 'typebox'}, 'unsupported cron schema evidence fields')
        require(set(row.get('captureRuntime', {})) == {'node'}
                and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', row['captureRuntime']['node']) is not None,
                'missing actual cron schema capture Node version')
        require(row.get('attemptedCalls') == [] and row.get('configBindings') == [],
                'cron schema evidence contains deferred calls or synthetic configuration')
        originals = {}
        loaded = row.get('loadedFiles', [])
        require(len(loaded) == len(paths) and {file.get('path') for file in loaded} == paths,
                'cron schema loaded-source boundary differs')
        for file in loaded:
            path = file['path']
            original = safe_path(fixtures / 'sources', path).read_bytes()
            digest = _hash(original)
            require(set(file) == {'path', 'sha256'} and file['sha256'] == tracked.get(path) == digest,
                    'cron loaded source snapshot/digest differs: ' + path)
            originals[path] = original
            expected_sources[path] = digest
        require(row.get('sourceSha256') == tracked.get(source), 'cron primary source digest differs')
        projected = paths & REGIONS.keys()
        whole = paths - projected
        executions = row.get('moduleExecutions', [])
        require(len(executions) == len(whole) and {item.get('source') for item in executions} == whole,
                'cron complete-module transformation set differs')
        for item in executions:
            require(set(item) == {'source', 'sourceSha256', 'kind', 'transformation', 'executableSha256'}
                    and item.get('kind') == 'complete-source-module' and item.get('transformation') == TRANSFORMATION
                    and item['sourceSha256'] == tracked.get(item['source']), 'cron complete source transformation differs')
            _digest(item.get('executableSha256'), require)
        projections = row.get('projections', [])
        require(len(projections) == len(projected) and {item.get('source') for item in projections} == projected,
                'cron source-region projection boundary differs')
        for item in projections:
            ranges, exports, prefix = REGIONS[item['source']]
            original = originals[item['source']]
            lines = original.splitlines(keepends=True)
            selections, parts = [], []
            for start, end in ranges:
                before, selected = b''.join(lines[:start - 1]), b''.join(lines[start - 1:end])
                selections.append({'kind': 'source-lines', 'startLine': start, 'endLine': end,
                                   'startByte': len(before), 'endByte': len(before + selected), 'sha256': _hash(selected)})
                parts.append(selected.decode())
            generated = prefix + '\n'.join(parts)
            require(set(item) == {'kind', 'source', 'sourceSha256', 'exports', 'selections', 'generatedCode',
                                  'generatedSha256', 'transformation', 'executableSha256'}
                    and item.get('kind') == 'cron-schema-source-regions' and item.get('exports') == exports
                    and item.get('sourceSha256') == tracked.get(item['source']) and item.get('selections') == selections
                    and item.get('generatedCode') == generated and item.get('generatedSha256') == _hash(generated)
                    and item.get('transformation') == TRANSFORMATION, 'cron exact source regions or generated wrapper differ')
            _digest(item.get('executableSha256'), require)
        is_input = source == INPUT_SOURCE
        target = 'packages/normalization-core/src/' + ('number-coercion.ts' if is_input else 'record-coerce.ts')
        require(row.get('sourceAliases') == [{'kind': 'whole-source-module',
                    'importer': INPUT_SOURCE if is_input else 'src/agents/schema/tool-output-schema.ts',
                    'specifier': '@openclaw/normalization-core/' + ('number-coercion' if is_input else 'record-coerce'),
                    'source': target, 'sourceSha256': tracked.get(target)}], 'cron normalization source alias differs')
        stubs = [{'importer': INPUT_SOURCE, 'specifier': specifier, 'exports': exports,
                  'kind': 'deferred-input-validation'} for specifier, exports in [
                      ('../../cron/pacing.js', ['parseCronPacingBounds']), ('../../utils.js', ['isRecord'])]] if is_input else []
        require(row.get('stubs') == stubs, 'cron deferred input-validation imports differ')
        schema = row.get('schema', {})
        parameters = schema.get('parameters')
        require(isinstance(parameters, dict) and set(schema) == {'parameters', 'schemaJson', 'schemaSha256', 'actions', 'actionlessBranches'}
                and json.loads(schema['schemaJson']) == parameters
                and schema['schemaJson'] == _json(parameters)
                and schema['schemaSha256'] == _hash(schema['schemaJson']) == schema_digest,
                'cron complete schema JSON or pinned digest differs')
        actions, actionless = _actions(parameters)
        require(schema['actions'] == actions and schema['actionlessBranches'] == actionless,
                'cron observed schema action index differs')
        if is_input:
            match = re.search(rb'const CRON_ACTIONS = \[([\s\S]*?)\] as const;', originals[source])
            require(match is not None, 'missing pinned default cron action constant')
            source_actions = sorted(re.findall(r'"([^"]+)"', match[1].decode()))
            require(parameters.get('type') == 'object' and parameters.get('required') == ['action']
                    and actions == source_actions, 'cron default input action index differs from pinned source')
        else:
            variant_source = originals[source].decode().split('  variants: {', 1)[1]
            variant_names = re.findall(r'^    ([a-z_]+):', variant_source, re.MULTILINE)
            annotation = parameters.get('x-openclaw-input-discriminator', {})
            require(annotation == {'version': 1, 'inputProperty': 'action',
                                   'mapping': {name: index for index, name in enumerate(variant_names)}}
                    and len(parameters.get('anyOf', [])) == len(variant_names) == 13,
                    'cron complete output discriminator mapping differs from original source')
        dependency = row.get('typebox', {})
        require(set(dependency) == {'version', 'exports', 'files'} and dependency.get('version') == '1.3.37'
                and _hash(_json(dependency['files'])) == dependency_digest,
                'cron real pinned TypeBox file inventory differs')
        files = {item['path']: item['sha256'] for item in dependency['files']}
        require(len(files) == len(dependency['files']), 'duplicate cron TypeBox dependency file')
        for path, digest in files.items():
            require(path.startswith('typebox/') and all(part not in ('', '.', '..') for part in path.split('/'))
                    and aggregate.get(path) == digest, 'cron TypeBox dependency differs from aggregate provenance')
            _digest(digest, require)
        exports = [{'specifier': specifier, 'path': path, 'sha256': files.get(path),
                    'packagePath': 'typebox/package.json', 'packageSha256': files.get('typebox/package.json')}
                   for specifier, path in [('typebox', 'typebox/build/index.mjs')]
                   + ([('typebox/value', 'typebox/build/value/index.mjs')] if is_input else [])]
        require(dependency.get('exports') == exports and all(item['sha256'] and item['packageSha256'] for item in exports),
                'cron real TypeBox package export provenance differs')
