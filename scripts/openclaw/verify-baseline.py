#!/usr/bin/env python3
"""Verify pinned OpenClaw reference facts without granting runtime authority.

Exit 0: complete; 1: invalid input/provenance; 2: valid inventory, incomplete
factory/assembly evidence or (with --require-coverage) capability coverage.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

from cron_schema_verification import verify_cron_schema_captures

from pdf_factory_verification import (
    PDF_FACTORY_SOURCE,
    verify_pdf_factory_recipe,
    verify_pdf_matrix,
    verify_pdf_projection,
)

from tts_factory_verification import (
    TTS_FACTORY_SOURCE,
    verify_tts_factory_recipe,
    verify_tts_matrix,
    verify_tts_projection,
)

from session_factory_verification import (
    verify_session_factory_recipe,
    verify_session_projection,
)

SESSION_FACTORY_SOURCES = {
    'src/agents/tools/sessions-list-tool.ts',
    'src/agents/tools/sessions-history-tool.ts',
    'src/agents/tools/session-status-tool.ts',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text())


def safe_path(root, name):
    require(isinstance(name, str) and name and '\\' not in name and not PurePosixPath(name).is_absolute() and all(x not in ('..', '.') for x in name.split('/')), f'unsafe source path: {name}')
    result = root / name
    require(result.resolve().is_relative_to(root.resolve()), f'source path escapes fixture root: {name}')
    return result


def names(values, label):
    require(isinstance(values, list) and all(isinstance(x, str) and x for x in values), f'invalid {label}')
    require(len(values) == len(set(values)), f'duplicate {label}')
    return set(values)


def files_by_path(rows, label, root):
    result = {}
    for row in rows:
        path = row['path']
        safe_path(root, path)
        require(path not in result, f'duplicate {label} path: {path}')
        require(re.fullmatch(r'[a-f0-9]{64}', row['sha256']) is not None, f'invalid {label} hash: {path}')
        result[path] = row['sha256']
    return result


def computed_counts(core, plugins, manifests):
    plugin_names = set()
    for plugin in plugins:
        plugin_names |= names(plugin['tools'], f"plugin tools: {plugin['plugin']}")
    return {
        'core': len(core), 'manifestsScanned': len(manifests), 'toolManifests': len(plugins),
        'uniquePluginTools': len(plugin_names), 'corePluginOverlap': len(core & plugin_names),
        'pluginOnly': len(plugin_names - core), 'union': len(core | plugin_names),
    }, core | plugin_names, plugin_names - core



def verify_projection_selection(projection, fixtures):
    if projection.get('kind', '').startswith('tts-'):
        verify_tts_projection(projection, fixtures, require, safe_path)
        return
    if projection.get('kind', '').startswith('pdf-'):
        verify_pdf_projection(projection, fixtures, require, safe_path)
        return
    if projection.get('kind', '').startswith('session-'):
        verify_session_projection(projection, fixtures, require, safe_path)
        return
    browser_root = 'extensions/browser/src/'
    constant_source = browser_root + 'browser/act-policy.ts'
    capability_sources = {
        browser_root + 'browser/engines/registry.ts',
        browser_root + 'browser/engines/lightpanda.ts',
    }
    source = projection['source']
    if source == 'packages/normalization-core/src/string-coerce.ts':
        require(set(projection) == {
            'importer', 'specifier', 'source', 'sourceSha256', 'exports',
            'kind', 'generatedCode', 'generatedSha256',
        }, 'unsupported normalization projection metadata')
        require(projection['importer'] == browser_root + 'browser-tool-binding.ts'
                and projection['specifier'] == 'openclaw/plugin-sdk/string-coerce-runtime'
                and projection['exports'] == ['normalizeOptionalString']
                and projection['kind'] == 'whole-module-export',
                'unsupported normalization export projection')
        generated = 'export {normalizeOptionalString} from ' + json.dumps('capture:source:' + source) + ';'
        require(projection['generatedCode'] == generated
                and projection['generatedSha256'] == hashlib.sha256(generated.encode()).hexdigest(),
                'normalization export wrapper differs from source-bound projection')
        return
    if source not in capability_sources | {constant_source} and not (
            'selection' in projection or 'generatedSha256' in projection):
        return  # Existing whole-module export projections retain their source checks.
    require(set(projection) == {
        'importer', 'specifier', 'source', 'sourceSha256', 'exports',
        'selection', 'generatedSha256',
    }, 'unsupported selected projection metadata')
    selection = projection['selection']
    require(isinstance(selection, dict) and set(selection) == {
        'kind', 'startByte', 'endByte', 'sha256',
    }, 'unsupported projection selection metadata')
    require(projection['importer'] == browser_root + 'browser-tool.schema.ts',
            'unsupported selected projection importer')
    kind = selection['kind']
    if kind == 'exported-constant':
        require(source == constant_source
                and projection['specifier'] == './browser/act-policy.js'
                and projection['exports'] == ['ACT_MAX_VIEWPORT_DIMENSION'],
                'unsupported exported-constant projection')
        pattern = rb'^(export const ACT_MAX_VIEWPORT_DIMENSION = [0-9_]+;)$'
    elif kind == 'complete-object-method':
        require(source in capability_sources
                and projection['specifier'] == 'capture:profile-capabilities'
                and projection['exports'] == ['capabilities'],
                'unsupported complete-object-method projection')
        pattern = rb'^(  capabilities\(profile\) \{[\s\S]*?^  \}),$'
    else:
        raise ValueError(f'unsupported projection selection kind: {kind}')
    snapshot = safe_path(fixtures / 'sources', source)
    require(snapshot.is_file(), f'missing projection source snapshot: {source}')
    original = snapshot.read_bytes()
    matches = list(re.finditer(pattern, original, re.MULTILINE))
    require(len(matches) == 1, f'projection must select exactly one original region: {source}')
    match = matches[0]
    start, end = selection['startByte'], selection['endByte']
    require(type(start) is int and type(end) is int
            and 0 <= start < end <= len(original)
            and (start, end) == match.span(1),
            f'projection selection byte range mismatch: {source}')
    selected = original[start:end]
    require(isinstance(selection['sha256'], str)
            and re.fullmatch(r'[a-f0-9]{64}', selection['sha256']) is not None
            and hashlib.sha256(selected).hexdigest() == selection['sha256'],
            f'projection selection hash mismatch: {source}')
    generated = (selected if kind == 'exported-constant' else
                 b'export const capabilities = ({\n' + selected + b'\n}).capabilities;')
    require(isinstance(projection['generatedSha256'], str)
            and re.fullmatch(r'[a-f0-9]{64}', projection['generatedSha256']) is not None
            and hashlib.sha256(generated).hexdigest() == projection['generatedSha256'],
            f'projection generated hash mismatch: {source}')


def verify_synthetic_config_input(binding, callback=False):
    common = {'kind', 'sourceImplementation', 'input', 'inputJson', 'inputSha256', 'generatedCode', 'generatedSha256'}
    require(set(binding) == (common if callback else common | {'importer', 'specifier', 'export', 'inputSource', 'calls'}),
            'unsupported synthetic config input metadata')
    require(binding['kind'] == 'synthetic-config-input'
            and binding['sourceImplementation'] == 'not-executed'
            and isinstance(binding['input'], dict),
            'synthetic config input must not claim runtime config implementation')
    # These bounded Browser inputs contain only ordinary JSON config fields.
    input_json = json.dumps(binding['input'], sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    require(binding['inputJson'] == input_json
            and binding['inputSha256'] == hashlib.sha256(input_json.encode()).hexdigest(),
            'synthetic config input bytes/hash mismatch')
    generated = ('()=>{globalThis.__captureConfigReads++;return ' if callback else
                 'export function readRuntimeConfig(){globalThis.__captureConfigReads++;return ') + input_json + ';}'
    require(binding['generatedCode'] == generated
            and binding['generatedSha256'] == hashlib.sha256(generated.encode()).hexdigest(),
            'synthetic config wrapper differs from recorded input')
    if not callback:
        require(binding['importer'] == 'extensions/browser/src/browser-tool.ts'
                and binding['specifier'] == 'openclaw/plugin-sdk/runtime-config-snapshot'
                and binding['export'] == 'readRuntimeConfig'
                and binding['inputSource'] in ('recipe.syntheticConfig', 'representativeContext.options.config')
                and type(binding['calls']) is int and binding['calls'] == 1,
                'unsupported Browser SDK synthetic config binding')


def verify_browser_factory_recipe(recipe, capture, tracked):
    require(recipe['export'] == 'createBrowserTool' and recipe['evidence'] == 'factory-return',
            'unsupported Browser factory recipe')
    bindings = recipe.get('configBindings', [])
    require(len(bindings) == 1, 'Browser factory must record its synthetic SDK config input')
    binding = bindings[0]
    verify_synthetic_config_input(binding)
    comparison = recipe.get('definitionComparison', {})
    require(comparison.get('freshVm') is True
            and comparison.get('source') == 'extensions/browser/src/browser-tool-description.ts'
            and comparison.get('sourceSha256') == tracked.get(comparison.get('source'))
            and comparison.get('export') == 'createBrowserToolDefinition'
            and comparison.get('selector') == 'metadata'
            and comparison.get('args') == recipe['args']
            and comparison.get('executeInvoked') is False
            and type(comparison.get('configReaderCalls')) is int and comparison['configReaderCalls'] == 1
            and comparison.get('attemptedCalls') == []
            and comparison.get('configBindings') == [],
            'Browser factory comparison must invoke the real definition in an independent equivalent VM')
    verify_synthetic_config_input(comparison.get('configReader', {}), callback=True)
    require(comparison['configReader']['input'] == binding['input'], 'definition config input differs from factory input')
    require(comparison.get('metadata') == {key: value for key, value in recipe['descriptor'].items() if key != 'executeObserved'}
            and any(row.get('path') == comparison['source'] and row.get('sha256') == comparison['sourceSha256']
                    for row in comparison.get('loadedFiles', [])),
            'independently invoked definition metadata differs from actual factory descriptor')
    context = recipe.get('representativeContext')
    if context:
        require(context in capture['contexts']
                and recipe['id'] == 'browser/factory/context/' + context['id']
                and recipe['context'] == 'recipe/context/' + context['id']
                and recipe['args'] == [context['options']]
                and binding['inputSource'] == 'representativeContext.options.config'
                and binding['input'] == context['options']['config'],
                'Browser representative config input differs from its actual context input')
    else:
        require(binding['inputSource'] == 'recipe.syntheticConfig', 'Browser variant must identify synthetic config input')
    require(recipe['eligibility']['status'] == 'unresolved' and recipe['registration']['status'] == 'unresolved',
            'Browser construction does not establish runtime admission or lazy registration')
    schema_id = recipe.get('schemaRecipe', recipe.get('constructorSchemaRecipe'))
    if schema_id:
        schemas = [row for row in capture['recipes'] if row['id'] == schema_id and row['status'] == 'captured']
        require(len(schemas) == 1 and schemas[0]['source'] == 'extensions/browser/src/browser-tool.schema.ts'
                and schemas[0]['schema']['parameters'] == recipe['schema']['parameters']
                and schemas[0]['capabilities'] == recipe['capabilities'],
                'Browser factory metadata differs from its source-backed schema variant')
    if recipe.get('schemaRecipe'):
        supplied = recipe.get('capabilityInput', {})
        schema = schemas[0]
        require(supplied.get('source') == schema['source'] and supplied.get('sourceSha256') == schema['sourceSha256']
                and supplied.get('export') == 'resolveBrowserToolCapabilities'
                and supplied.get('params') == schema['args'][0]
                and supplied.get('evidence') == 'supplied-capabilities; no host config/profile resolution'
                and recipe['args'] == [{'toolCapabilities': recipe['capabilities']}]
                and binding['input'] == {},
                'Browser supplied capabilities must retain source-backed input provenance')
    require(recipe['schema']['actions'] == sorted(recipe['capabilities']['actions'])
            and recipe['schema']['parameters']['properties']['kind']['enum'] == recipe['capabilities']['actKinds'],
            'Browser captured action/kind metadata differs from capabilities')
    output = recipe.get('outputSchema', {})
    require(recipe['descriptor'].get('outputSchema') == output.get('parameters')
            and json.loads(output['schemaJson']) == output['parameters']
            and hashlib.sha256(output['schemaJson'].encode()).hexdigest() == output['schemaSha256'],
            'Browser output schema bytes/hash differ from actual descriptor')


def verify_browser_registrations(capture, fixtures, tracked, expected_sources):
    rows = capture.get('browserRegistrations', [])
    require(isinstance(rows, list), 'Browser registration captures must be an array')
    ids = [row['id'] for row in rows]
    require(len(ids) == len(set(ids)), 'duplicate Browser registration callback capture')
    registration_source = 'extensions/browser/plugin-registration.ts'
    definition_source = 'extensions/browser/src/browser-tool-description.ts'
    prefix = '''import {createBrowserToolDefinition as upstreamCreateBrowserToolDefinition} from "capture:browser-definition";
const registration={callback:undefined,options:undefined,calls:0};
const api={registerTool(callback,options){registration.callback=callback;registration.options=options;registration.calls++;}};
function createBrowserToolDefinition(opts,getConfig){
  globalThis.__captureDefinitionOptions=opts;
  return upstreamCreateBrowserToolDefinition(opts,()=>{
    const config=getConfig();
    globalThis.__captureDefinitionConfig=config;
    globalThis.__captureDefinitionConfigReads++;
    return config;
  });
}
function loadBrowserRegistrationRuntimeModule(){
  globalThis.__captureAudit.push({kind:"execution-service",export:"loadBrowserRegistrationRuntimeModule"});
  throw Error("blocked Browser registration runtime");
}
'''
    suffix = '\nexport {registration};\n'
    dump = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    dependencies = {row['path']: row['sha256'] for row in capture['dependencies']}
    for row in rows:
        require(row.get('source') == registration_source
                and row.get('sourceSha256') == tracked.get(registration_source)
                and row.get('evidence') == 'projected-registerTool-callback'
                and row.get('executeInvoked') is False,
                'Browser callback must identify its source and limited evidence')
        require(row.get('boundaries') == dict.fromkeys([
            'fullPluginRegistrationInvoked', 'pluginLoaderInvoked', 'runtimeAdmissionExecuted',
            'servicesStarted', 'runtimeModuleLoaded', 'actionsExecuted'], False),
                'Browser callback projection must preserve unexecuted boundaries')
        evidence_rows = [row]
        if row.get('status') == 'captured':
            require(row.get('attemptedCalls') == [] and row.get('descriptorMatch') is True,
                    'Browser callback capture contains unresolved effects or metadata')
            require(sum(projection.get('kind') == 'browser-registration-regions'
                        for projection in row.get('projections', [])) == 1
                    and any(item.get('path') == registration_source
                            and item.get('sha256') == row['sourceSha256']
                            for item in row.get('loadedFiles', [])),
                    'Browser callback capture must include its exact projection and source')
            require(row.get('registration') == {
                'options': {'name': 'browser', 'workspaceAccess': False},
                'registerToolCalls': 1, 'callbackInvoked': True,
                'fullPluginRegistrationInvoked': False}, 'Browser registerTool observation differs')
            source_input = row['input']
            ctx = source_input['context']
            getter = source_input.get('getRuntimeConfig')
            if getter and getter['returnKind'] == 'value':
                selected, origin = getter['value'], 'ctx.getRuntimeConfig()'
            elif ctx.get('runtimeConfig') is not None:
                selected, origin = ctx['runtimeConfig'], 'ctx.runtimeConfig'
            else:
                selected, origin = ctx['config'], 'ctx.config'
            require(isinstance(selected, dict), 'Browser callback config input must be an object')
            selection = row['configSelection']
            require(selection['origin'] == origin and selection['input'] == selected
                    and selection['inputJson'] == dump(selected)
                    and selection['inputSha256'] == digest(dump(selected))
                    and type(selection['getterCalls']) is int
                    and selection['getterCalls'] == int(getter is not None)
                    and type(selection['definitionReaderCalls']) is int
                    and selection['definitionReaderCalls'] == 1,
                    'Browser callback config selection differs from recorded input')
            getter_value = dump(getter['value']) if getter and getter['returnKind'] == 'value' else 'undefined'
            getter_code = '()=>{globalThis.__captureContextConfigReads++;return ' + getter_value + ';}'
            setup = 'globalThis.__captureContext=' + dump(ctx) + ';globalThis.__captureContextConfigReads=0;globalThis.__captureDefinitionConfigReads=0;'
            if getter:
                setup += 'globalThis.__captureContext.getRuntimeConfig=' + getter_code + ';'
            require(row['contextBinding'] == {
                'kind': 'synthetic-context-input', 'sourceImplementation': 'not-executed',
                'generatedCode': setup, 'generatedSha256': digest(setup)},
                    'Browser synthetic callback context wrapper differs')
            expected_options = {}
            for source_key, target_key in [('sessionKey', 'agentSessionKey'), ('agentId', 'agentId'),
                                           ('agentDir', 'agentDir'), ('workspaceDir', 'workspaceDir')]:
                if ctx.get(source_key):
                    expected_options[target_key] = ctx[source_key]
            model = ctx.get('activeModel', {})
            if model.get('provider') or model.get('modelId'):
                expected_options['activeModel'] = {key: model[source_key]
                    for key, source_key in [('provider', 'provider'), ('model', 'modelId')] if source_key in model}
            channel = ctx.get('deliveryContext', {}).get('channel', ctx.get('messageChannel'))
            if ctx.get('sessionKey') or channel:
                media = {}
                if ctx.get('sessionKey'):
                    media['sessionKey'] = ctx['sessionKey']
                if channel:
                    media['channel'] = channel
                tokens = set(ctx.get('sessionKey', '').lower().split(':'))
                chat = next((kind for kind in ['group', 'channel', 'direct'] if kind in tokens),
                            'direct' if 'dm' in tokens else None)
                if chat:
                    media['chatType'] = chat
                expected_options['mediaScope'] = media
            if 'browser' in ctx.get('toolBindings', {}):
                expected_options['runToolBinding'] = ctx['toolBindings']['browser']
            require(row['options'] == expected_options, 'Browser ordinary callback options differ from source context')
            comparison = row['definitionComparison']
            require(any(item.get('path') == definition_source
                        and item.get('sha256') == tracked.get(definition_source)
                        for item in comparison.get('loadedFiles', [])),
                    'Browser callback comparison must include the real definition source')
            config_json = dump(selected)
            config_code = '()=>{globalThis.__captureConfigReads++;return ' + config_json + ';}'
            require(comparison.get('freshVm') is True and comparison.get('source') == definition_source
                    and comparison.get('sourceSha256') == tracked.get(definition_source)
                    and comparison.get('export') == 'createBrowserToolDefinition'
                    and comparison.get('selector') == 'metadata' and comparison.get('args') == [row['options']]
                    and comparison.get('executeInvoked') is False and comparison.get('attemptedCalls') == []
                    and comparison.get('configInput') == {
                        'kind': 'synthetic-config-input', 'sourceImplementation': 'not-executed',
                        'origin': origin, 'input': selected, 'inputJson': config_json,
                        'inputSha256': digest(config_json), 'generatedCode': config_code,
                        'generatedSha256': digest(config_code), 'calls': 1},
                    'Browser callback comparison must use a fresh real definition with equivalent input')
            require(row['descriptor'].get('executeObserved') is True
                    and comparison['metadata'] == {key: value for key, value in row['descriptor'].items() if key != 'executeObserved'},
                    'Browser callback full metadata differs from independent definition')
            for key, descriptor_key in [('schema', 'parameters'), ('outputSchema', 'outputSchema')]:
                schema = row[key]
                require(schema['parameters'] == row['descriptor'][descriptor_key]
                        and json.loads(schema['schemaJson']) == schema['parameters']
                        and digest(schema['schemaJson']) == schema['schemaSha256'],
                        'Browser callback schema/output bytes or hash differ')
            require(row['schema']['actions'] == sorted(comparison['capabilities']['actions'])
                    and row['schema']['parameters']['properties']['kind']['enum'] == comparison['capabilities']['actKinds'],
                    'Browser callback schema differs from definition capabilities')
            if 'representativeContext' in row:
                context = row['representativeContext']
                require(context in capture['contexts'] and row['context'] == context['id']
                        and row['id'] == 'browser/registration/context/' + context['id']
                        and ctx == {'sessionKey': context['options']['agentSessionKey'], 'agentId': 'reference',
                                    'workspaceDir': '/reference/workspace', 'config': context['options']['config']},
                        'Browser callback representative context differs from source input')
            evidence_rows.append(comparison)
        for evidence in evidence_rows:
            typebox = evidence.get('typebox', {})
            if typebox.get('files') or row.get('status') == 'captured':
                require(typebox.get('version') == '1.3.37', 'Browser callback TypeBox version differs')
            for item in typebox.get('files', []):
                require(dependencies.get(item['path']) == item['sha256'], 'Browser callback dependency provenance differs')
            for item in evidence.get('loadedFiles', []):
                require(tracked.get(item['path']) == item['sha256'], 'Browser callback loaded source hash differs')
                expected_sources[item['path']] = item['sha256']
            for projection in evidence.get('projections', []):
                require(tracked.get(projection['source']) == projection['sourceSha256'], 'Browser callback projection source differs')
                expected_sources[projection['source']] = projection['sourceSha256']
                if projection.get('kind') != 'browser-registration-regions':
                    verify_projection_selection(projection, fixtures)
                    continue
                require(projection['source'] == registration_source
                        and projection['wrapperVersion'] == 'browser-registration-v1'
                        and projection['importer'] == 'capture:browser-registration'
                        and projection['specifier'] == 'capture:registration-callback'
                        and projection['exports'] == ['registration'], 'unsupported Browser callback projection')
                original = safe_path(fixtures / 'sources', registration_source).read_bytes()
                selections = projection['selections']
                regions = [('deriveChatTypeFromSessionKey', 'complete-function'), ('createLazyBrowserTool', 'complete-function'),
                           ('createBrowserToolOptions', 'complete-function'), ('api.registerTool', 'complete-statement')]
                require([(item['name'], item['kind']) for item in selections] == regions,
                        'Browser callback projection regions differ')
                for item in selections:
                    pattern = (rb'^  api\.registerTool\([\s\S]*?^  \);$' if item['kind'] == 'complete-statement' else
                               rb'^function ' + item['name'].encode() + rb'\([\s\S]*?^\}')
                    matches = list(re.finditer(pattern, original, re.MULTILINE))
                    require(len(matches) == 1 and (item['startByte'], item['endByte']) == matches[0].span(),
                            'Browser callback projection source byte selection differs')
                    selected_bytes = original[item['startByte']:item['endByte']]
                    require(selected_bytes.decode() == item['selectedCode']
                            and hashlib.sha256(selected_bytes).hexdigest() == item['sha256'],
                            'Browser callback selected source bytes/hash differ')
                generated = prefix + '\n\n'.join(item['selectedCode'] for item in selections) + suffix
                require(projection['generatedCode'] == generated and projection['generatedSha256'] == digest(generated)
                        and projection['transformation'] == 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)'
                        and re.fullmatch(r'[a-f0-9]{64}', projection['executableSha256']) is not None,
                        'Browser callback generated source wrapper/hash differs')


def verify_inventory(manifest, capture, fixtures):
    require(capture['schemaVersion'] == 1, 'unsupported capture schemaVersion')
    source = capture['source']
    require(source.get('verified') is True and source['commit'] == manifest['sha'], 'source pin is not verified or does not match manifest')
    require(re.fullmatch(r'[a-f0-9]{40}', source['tree']) is not None, 'invalid source tree hash')
    tracked = files_by_path(source['files'], 'tracked source', fixtures)
    baseline_manifests = files_by_path(manifest['scannedManifests'], 'baseline manifest', fixtures)
    inventory = capture['inventory']
    captured_manifests = files_by_path(inventory['scannedManifests'], 'captured manifest', fixtures)
    require(captured_manifests == baseline_manifests, 'captured manifest inventory or hashes differ from baseline')
    core = names(inventory['core'], 'captured core names')
    require(core == names(manifest['core'], 'baseline core names'), 'core name inventory differs from baseline')
    expected_plugins = {x['plugin']: x for x in manifest['plugins']}
    actual_plugins = {x['plugin']: x for x in inventory['plugins']}
    require(len(expected_plugins) == len(manifest['plugins']) and len(actual_plugins) == len(inventory['plugins']), 'duplicate plugin inventory')
    require(actual_plugins.keys() == expected_plugins.keys(), 'tool manifest plugin set differs from baseline')
    for plugin, expected in expected_plugins.items():
        actual = actual_plugins[plugin]
        for field in ('source', 'sourceSha256'):
            require(actual[field] == expected[field], f'plugin source/hash mismatch: {plugin}')
        require(names(actual['tools'], f'plugin {plugin}') == names(expected['tools'], f'baseline plugin {plugin}'), f'plugin tool inventory mismatch: {plugin}')
    counts, union, plugin_only = computed_counts(core, inventory['plugins'], captured_manifests)
    require(counts == manifest['counts'] == inventory['counts'], 'inventory counts differ from recomputed baseline counts')
    require(union == names(manifest['union'], 'baseline union') == names(inventory['union'], 'captured union'), 'union inventory differs from baseline')
    require(plugin_only == names(manifest['pluginOnly'], 'baseline pluginOnly'), 'pluginOnly differs from baseline')
    expected_sources = {manifest['coreSource']['path']: manifest['coreSource']['sha256'], **baseline_manifests}
    licenses = files_by_path(capture['licenses'], 'source license', fixtures)
    require('LICENSE' in licenses, 'missing copied root LICENSE provenance')
    expected_sources.update(licenses)
    verify_cron_schema_captures(capture, tracked, fixtures, expected_sources, require, safe_path)
    verify_pdf_matrix(capture, require)
    verify_tts_matrix(capture, require)
    for recipe in capture.get('recipes', []):
        require(recipe.get('executeInvoked') is False, 'recipe must not invoke execute')
        browser_factory = recipe.get('source') == 'extensions/browser/src/browser-tool.ts'
        session_factory = recipe.get('source') in SESSION_FACTORY_SOURCES
        pdf_factory = recipe.get('source') == PDF_FACTORY_SOURCE
        tts_factory = recipe.get('source') == TTS_FACTORY_SOURCE
        require(recipe.get('context') == 'recipe/default' or browser_factory or session_factory or pdf_factory or tts_factory,
                'recipe construction is not runtime eligibility evidence')
        typebox = recipe.get('typebox', {})
        if typebox.get('files') or typebox.get('version') is not None:
            require(typebox.get('version') == '1.3.37', 'recipe TypeBox dependency must be pinned to 1.3.37')
        if recipe.get('sourceSha256'):
            require(tracked.get(recipe['source']) == recipe['sourceSha256'], 'recipe source hash mismatch')
        if recipe.get('status') == 'captured':
            recipe_source = recipe.get('source')
            recipe_hash = recipe.get('sourceSha256')
            require(isinstance(recipe_source, str) and isinstance(recipe_hash, str)
                    and re.fullmatch(r'[a-f0-9]{64}', recipe_hash) is not None
                    and tracked.get(recipe_source) == recipe_hash,
                    'captured recipe source must have a valid tracked source/hash')
            require(any(row.get('path') == recipe_source and row.get('sha256') == recipe_hash
                        for row in recipe.get('loadedFiles', [])),
                    'captured recipe source must have a matching loaded-file entry')
            require(not recipe.get('attemptedCalls'), 'captured recipe contains blocked execution attempts')
            require(recipe['evidence'] in ('schema-export', 'factory-return'), 'invalid recipe evidence kind')
            if recipe['evidence'] == 'factory-return':
                require(recipe.get('descriptorMatch') is True, 'factory descriptor does not match schema definition')
                if browser_factory:
                    verify_browser_factory_recipe(recipe, capture, tracked)
                if session_factory:
                    verify_session_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path)
                if pdf_factory:
                    verify_pdf_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path)
                if tts_factory:
                    verify_tts_factory_recipe(recipe, capture, tracked, fixtures, require, safe_path)
            schema = recipe['schema']
            require(json.loads(schema['schemaJson']) == schema['parameters'], 'recipe schema bytes differ from parameters')
            require(hashlib.sha256(schema['schemaJson'].encode()).hexdigest() == schema['schemaSha256'], 'recipe schema hash mismatch')
        for evidence in [recipe] + ([recipe['definitionComparison']] if 'definitionComparison' in recipe else []):
            if evidence.get('typebox', {}).get('files'):
                require(evidence['typebox'].get('version') == '1.3.37', 'comparison TypeBox dependency must be pinned to 1.3.37')
            for row in evidence.get('loadedFiles', []):
                require(tracked.get(row['path']) == row['sha256'], 'recipe loaded-file hash mismatch')
                expected_sources[row['path']] = row['sha256']
            for projection in evidence.get('projections', []):
                require(tracked.get(projection['source']) == projection['sourceSha256'], 'recipe projection source hash mismatch')
                expected_sources[projection['source']] = projection['sourceSha256']
                verify_projection_selection(projection, fixtures)
    verify_browser_registrations(capture, fixtures, tracked, expected_sources)
    for path, expected in expected_sources.items():
        require(tracked.get(path) == expected, f'tracked source hash mismatch: {path}')
        snapshot = safe_path(fixtures / 'sources', path)
        require(snapshot.is_file(), f'missing source snapshot: {path}')
        require(hashlib.sha256(snapshot.read_bytes()).hexdigest() == expected, f'snapshot hash mismatch: {path}')
    for plugin in inventory['plugins']:
        raw = read_json(safe_path(fixtures / 'sources', plugin['source']))
        require(raw['id'] == plugin['plugin'], f'plugin ID differs from source: {plugin["plugin"]}')
        require(names(raw.get('contracts', {}).get('tools', raw.get('tools', [])), 'manifest source tools') == set(plugin['tools']), f'tool declarations differ from manifest source: {plugin["plugin"]}')
    for row in capture['factories'] + capture['registrations']:
        safe_path(fixtures, row['source'])
        require(tracked.get(row['source']) == row['sourceSha256'], f'factory/registration source hash mismatch: {row["source"]}')
    return counts, union


def completeness(capture, union):
    gaps = list(capture.get('completeness', {}).get('gaps', []))
    for recipe in capture.get('recipes', []) + [row for row in capture.get('schemaCaptures', []) if row.get('evidence') == 'schema-builder']:
        if recipe.get('status') != 'captured':
            gaps.append({'kind': 'unresolved-recipe', 'recipe': recipe['id']})
        else:
            for action in recipe['schema']['actions'] + (['$call'] if recipe['schema']['actionlessBranches'] else []):
                if not any(x.get('kind') == 'missing-action-cases' and x.get('tool') == recipe['referenceTool'] and x.get('action') == action for x in gaps):
                    gaps.append({'kind': 'missing-action-cases', 'tool': recipe['referenceTool'], 'action': action})
    expected_contexts = {f'{role}/{profile}/{config}' for role in ['primary', 'child', 'scheduled'] for profile in ['minimal', 'coding', 'messaging', 'full'] for config in ['configured', 'unconfigured']}
    contexts = {x['id'] for x in capture['contexts']}
    for context in sorted(expected_contexts - contexts):
        gaps.append({'kind': 'missing-context', 'context': context})
    executed = set()
    candidates = {}
    for row in capture['factories']:
        key = (row['source'], row['export'])
        seen = candidates.setdefault(key, set())
        require(row['context'] not in seen, 'duplicate factory/context evidence')
        seen.add(row['context'])
        require(row['status'] in ('executed', 'ineligible', 'unresolved'), 'unknown factory capture status')
        if row['status'] == 'executed':
            require(not row.get('attemptedCalls'), 'executed factory contains blocked execution attempts')
            require(row.get('evidence') == 'factory-invocation', 'static parsing cannot claim executed factory evidence')
            tool = row['tool']
            require(isinstance(tool['parameters'], dict), 'factory parameters must be JSON schema objects')
            # Hash the exact captured JS serialization: Python serializes small
            # numbers differently (1e-07 vs 1e-7). Still compare decoded schemas.
            schema_json = tool['schemaJson']
            require(json.loads(schema_json) == tool['parameters'], 'factory schema bytes differ from parameters')
            actual = hashlib.sha256(schema_json.encode()).hexdigest()
            require(tool['schemaSha256'] == actual, 'factory schema hash mismatch')
            executed.add(tool['name'])
        elif row['status'] == 'unresolved':
            gaps.append({'kind': 'unresolved-factory', 'source': row['source'], 'export': row['export'], 'context': row['context']})
    for (source, factory), seen in candidates.items():
        for context in sorted(expected_contexts - seen):
            gaps.append({'kind': 'missing-factory-context', 'source': source, 'export': factory, 'context': context})
    for tool in sorted(union - executed):
        gaps.append({'kind': 'missing-factory', 'tool': tool})
    assemblies = {x['context'] for x in capture.get('assemblies', []) if x.get('status') == 'executed'}
    for context in sorted(expected_contexts - assemblies):
        gaps.append({'kind': 'unresolved-assembly-context', 'context': context})
    for row in capture['registrations']:
        if row.get('assemblyStatus') != 'executed':
            gaps.append({'kind': 'unresolved-registration', 'source': row['source'], 'line': row['line']})
    return gaps


def coverage_gaps(fixtures, manifest, capture, union):
    path = fixtures / 'capability-map.json'
    if not path.is_file():
        return [{'kind': 'missing-capability-map', 'file': 'capability-map.json'}]
    mapping = read_json(path)
    require(mapping['schemaVersion'] == 1 and mapping['referenceCommit'] == manifest['sha'], 'capability-map pin/schema mismatch')
    require(mapping['runtimeContractAuthority'] == 'backplane_agent_runtime', 'capability-map runtime authority mismatch')
    expected_version = manifest.get('planning', {}).get('runtimeContractBaseline', {}).get('version')
    if expected_version:
        require(mapping['runtimeVersion'] == expected_version, 'capability-map runtime version mismatch')
    rows = mapping['coverage']
    require(names([x['referenceTool'] for x in rows], 'capability coverage names') == union, 'capability-map must cover the exact reference union')
    gaps = []
    for row in rows:
        tool = row['referenceTool']
        require(row['disposition'] in ('native-reuse', 'host-extension', 'host-adapted', 'gap'), f'invalid mapping disposition: {tool}')
        evidence = row.get('evidence', {})
        if row['disposition'] == 'gap' or not row.get('targetTools') or evidence.get('implementation') != 'implemented' or evidence.get('localContractVerified') is not True:
            gaps.append({'kind': 'unverified-capability', 'tool': tool})
        # External live verification is distinct and is never inferred from local tests.
        actions = set()
        for factory in capture['factories']:
            if factory['status'] == 'executed' and factory['tool']['name'] == tool:
                actions.update(factory['tool']['actions'] or ['$call'])
        for recipe in capture.get('recipes', []) + [item for item in capture.get('schemaCaptures', []) if item.get('evidence') == 'schema-builder']:
            if recipe['status'] == 'captured' and recipe['referenceTool'] == tool:
                actions.update(recipe['schema']['actions'])
                if recipe['schema']['actionlessBranches']:
                    actions.add('$call')
        action_rows = {x['action']: x for x in row.get('referenceActions', [])}
        for action in sorted(actions):
            sample = action_rows.get(action, {})
            if not all(sample.get('cases', {}).get(case) for case in ('valid', 'invalid', 'denied', 'unavailable')) or not sample.get('effectExpectation') or not sample.get('resultExpectation'):
                gaps.append({'kind': 'missing-action-evidence', 'tool': tool, 'action': action})
            if sample.get('resourceLifecycle') is True and not all(sample.get('lifecycle', {}).get(case) for case in ('timeout', 'cancel', 'ownerLoss', 'restore')):
                gaps.append({'kind': 'missing-lifecycle-evidence', 'tool': tool, 'action': action})
    return gaps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--require-coverage', action='store_true')
    args = parser.parse_args()
    try:
        manifest = read_json(args.manifest)
        capture = read_json(args.fixtures / 'capture.json')
        counts, union = verify_inventory(manifest, capture, args.fixtures)
        gaps = completeness(capture, union)
        if args.require_coverage:
            gaps.extend(coverage_gaps(args.fixtures, manifest, capture, union))
        # Preserve first occurrence, avoiding repeated gap rows from independent checks.
        gaps = list({json.dumps(x, sort_keys=True): x for x in gaps}.values())
        print(json.dumps({'inventoryVerified': True, 'counts': counts, 'complete': not gaps, 'gaps': gaps}, sort_keys=True))
        return 2 if gaps else 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f'verify-baseline: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
