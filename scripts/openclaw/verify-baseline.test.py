import hashlib
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('verify-baseline.py')


class VerifyBaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='openclaw-verify-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fixtures = self.root / 'fixtures'
        self.fixtures.mkdir()
        self.commit = 'a' * 40
        self.catalog = {'path': 'src/agents/tool-catalog.ts', 'sha256': self.snapshot('src/agents/tool-catalog.ts', 'catalog')}
        self.license = {'path': 'LICENSE', 'sha256': self.snapshot('LICENSE', 'MIT License\nTest fixture\n')}
        self.plugin = {'path': 'extensions/sample/openclaw.plugin.json', 'sha256': self.snapshot('extensions/sample/openclaw.plugin.json', '{"id":"sample","contracts":{"tools":["plugin"]}}')}
        self.counts = {'core': 1, 'manifestsScanned': 1, 'toolManifests': 1, 'uniquePluginTools': 1, 'corePluginOverlap': 0, 'pluginOnly': 1, 'union': 2}
        self.plugins = [{'plugin': 'sample', 'source': self.plugin['path'], 'sourceSha256': self.plugin['sha256'], 'tools': ['plugin']}]
        self.baseline = {'sha': self.commit, 'core': ['core'], 'plugins': self.plugins, 'pluginOnly': ['plugin'], 'union': ['core', 'plugin'], 'counts': self.counts, 'coreSource': self.catalog, 'scannedManifests': [self.plugin]}
        self.capture = {
            'schemaVersion': 1, 'source': {'commit': self.commit, 'tree': 'b' * 40, 'verified': True, 'files': [self.catalog, self.plugin, self.license]},
            'inventory': {'core': ['core'], 'plugins': self.plugins, 'scannedManifests': [self.plugin], 'union': ['core', 'plugin'], 'counts': self.counts},
            'contexts': [], 'factories': [], 'registrations': [], 'completeness': {'complete': False, 'gaps': [{'kind': 'missing-factory', 'tool': 'core'}]},
            'licenses': [self.license],
        }

    def snapshot(self, path, content):
        target = self.fixtures / 'sources' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return hashlib.sha256(content.encode()).hexdigest()

    def run_cli(self, *args):
        manifest = self.root / 'baseline.json'
        manifest.write_text(json.dumps(self.baseline))
        (self.fixtures / 'capture.json').write_text(json.dumps(self.capture))
        return subprocess.run(['python3', str(SCRIPT), '--manifest', str(manifest), '--fixtures', str(self.fixtures), *args], capture_output=True, text=True, timeout=10)

    def test_inventory_is_verified_but_missing_factories_fail_completeness(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['inventoryVerified'])
        self.assertFalse(report['complete'])
        self.assertGreater(len(report['gaps']), 0)

    def test_tampered_source_snapshot_and_manifest_hash_are_rejected(self):
        (self.fixtures / 'sources' / self.catalog['path']).write_text('tampered')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn('hash', result.stderr.lower())
        self.snapshot(self.catalog['path'], 'catalog')
        self.capture['inventory']['scannedManifests'] = [{**self.plugin, 'sha256': '0' * 64}]
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn('manifest', result.stderr.lower())

    def test_wrong_pin_inventory_duplicates_and_path_traversal_are_rejected(self):
        self.capture['source']['commit'] = 'f' * 40
        self.assertEqual(self.run_cli().returncode, 1)
        self.capture['source']['commit'] = self.commit
        self.capture['inventory']['core'] = ['core', 'core']
        self.assertEqual(self.run_cli().returncode, 1)
        self.capture['inventory']['core'] = ['core']
        self.capture['source']['files'].append({'path': '../escape', 'sha256': '0' * 64})
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn('path', result.stderr.lower())

    def test_completeness_claim_does_not_hide_unresolved_or_absent_contexts(self):
        self.capture['completeness'] = {'complete': True, 'gaps': []}
        self.capture['factories'] = [{'source': self.catalog['path'], 'sourceSha256': self.catalog['sha256'], 'export': 'createCoreTool', 'context': 'primary/full/configured', 'status': 'unresolved'}]
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(json.loads(result.stdout)['complete'])

    def test_require_coverage_rejects_planned_and_missing_mapping(self):
        result = self.run_cli('--require-coverage')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('capability-map', result.stdout)
        mapping = {'schemaVersion': 1, 'referenceCommit': self.commit, 'runtimeContractAuthority': 'backplane_agent_runtime', 'runtimeVersion': '1.10.28', 'coverage': [{'referenceTool': x, 'disposition': 'native-reuse', 'targetTools': ['different_native_name'], 'nativeFamilies': ['native_family'], 'evidence': {'implementation': 'planned', 'localContractVerified': False, 'liveVerified': False}} for x in ['core', 'plugin']]}
        (self.fixtures / 'capability-map.json').write_text(json.dumps(mapping))
        result = self.run_cli('--require-coverage')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('unverified', result.stdout)

    def test_schema_hash_preserves_javascript_number_serialization(self):
        schema_json = '{"properties":{"value":{"minimum":1e-7,"type":"number"}},"type":"object"}'
        self.capture['factories'] = [{
            'source': self.catalog['path'], 'sourceSha256': self.catalog['sha256'], 'export': 'createCoreTool',
            'context': 'primary/full/configured', 'status': 'executed', 'evidence': 'factory-invocation',
            'tool': {'name': 'core', 'parameters': json.loads(schema_json), 'schemaJson': schema_json,
                     'schemaSha256': hashlib.sha256(schema_json.encode()).hexdigest(), 'actions': []},
        }]
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(json.loads(result.stdout)['inventoryVerified'])

    def test_copied_license_provenance_is_required_and_checked(self):
        (self.fixtures / 'sources/LICENSE').write_text('tampered license')
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('hash', result.stderr)

    def test_recipe_dependency_version_cannot_be_tampered_or_omitted_when_used(self):
        self.capture['recipes'] = [{
            'id': 'test/schema', 'executeInvoked': False, 'context': 'recipe/default',
            'status': 'unresolved', 'typebox': {'version': '9.9.9', 'files': [{'path': 'typebox/package.json', 'sha256': 'f' * 64}]},
        }]
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('TypeBox', result.stderr)
        self.capture['recipes'][0]['typebox']['version'] = None
        self.assertEqual(self.run_cli().returncode, 1)
        self.capture['recipes'][0]['typebox']['version'] = '1.3.37'
        self.assertEqual(self.run_cli().returncode, 2)
        self.capture['recipes'][0]['typebox'] = {'version': None, 'files': []}
        self.assertEqual(self.run_cli().returncode, 2)

    def test_captured_recipe_requires_a_tracked_source_and_matching_loaded_file(self):
        schema_json = '{"type":"object"}'
        valid = deepcopy(self.capture)
        valid['recipes'] = [{
            'id': 'test/schema', 'referenceTool': 'core', 'executeInvoked': False,
            'context': 'recipe/default', 'status': 'captured', 'evidence': 'schema-export',
            'source': self.catalog['path'], 'sourceSha256': self.catalog['sha256'],
            'loadedFiles': [dict(self.catalog)], 'attemptedCalls': [],
            'schema': {'parameters': json.loads(schema_json), 'schemaJson': schema_json,
                       'schemaSha256': hashlib.sha256(schema_json.encode()).hexdigest(),
                       'actions': [], 'actionlessBranches': 1},
        }]
        self.capture = deepcopy(valid)
        self.assertEqual(self.run_cli().returncode, 2)
        for changes in [
            {'source': 'forged/nonexistent.ts', 'sourceSha256': None},
            {'sourceSha256': None},
            {'loadedFiles': []},
        ]:
            with self.subTest(changes=changes):
                self.capture = deepcopy(valid)
                self.capture['recipes'][0].update(changes)
                result = self.run_cli()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('recipe source', result.stderr)

    def test_executed_factory_cannot_contain_a_blocked_execution_attempt(self):
        schema_json = '{"type":"object"}'
        valid = deepcopy(self.capture)
        valid['factories'] = [{
            'source': self.catalog['path'], 'sourceSha256': self.catalog['sha256'],
            'export': 'createCoreTool', 'context': 'primary/full/configured',
            'status': 'executed', 'evidence': 'factory-invocation', 'attemptedCalls': [],
            'tool': {'name': 'core', 'parameters': json.loads(schema_json),
                     'schemaJson': schema_json, 'schemaSha256': hashlib.sha256(schema_json.encode()).hexdigest(),
                     'actions': []},
        }]
        self.capture = deepcopy(valid)
        self.assertEqual(self.run_cli().returncode, 2)
        self.capture = deepcopy(valid)
        self.capture['factories'][0]['attemptedCalls'] = [{'kind': 'dynamic-import', 'specifier': 'node:fs'}]
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('executed factory contains blocked execution attempts', result.stderr)


if __name__ == '__main__':
    unittest.main()
