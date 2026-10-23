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
    for recipe in capture.get('recipes', []):
        require(recipe.get('executeInvoked') is False, 'recipe must not invoke execute')
        require(recipe.get('context') == 'recipe/default', 'recipe construction is not runtime eligibility evidence')
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
            schema = recipe['schema']
            require(json.loads(schema['schemaJson']) == schema['parameters'], 'recipe schema bytes differ from parameters')
            require(hashlib.sha256(schema['schemaJson'].encode()).hexdigest() == schema['schemaSha256'], 'recipe schema hash mismatch')
        for row in recipe.get('loadedFiles', []):
            require(tracked.get(row['path']) == row['sha256'], 'recipe loaded-file hash mismatch')
            expected_sources[row['path']] = row['sha256']
        for projection in recipe.get('projections', []):
            require(tracked.get(projection['source']) == projection['sourceSha256'], 'recipe projection source hash mismatch')
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
    for recipe in capture.get('recipes', []):
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
        for recipe in capture.get('recipes', []):
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
