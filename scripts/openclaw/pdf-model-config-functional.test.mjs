// Ordinary successful configuration selection. Availability is an explicit fixture port.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {capturePdfModelConfig} from './capture-pdf-model-config.mjs';

const root = process.env.OPENCLAW_PDF_SOURCE ?? '/tmp/openclaw-488631c';
const receipt = await capturePdfModelConfig(root);
const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/pdf-model-config.json', import.meta.url)));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
// These literal outputs were frozen with the independent original-source oracle,
// before the host implementation existed. Explicit-source quirks remain visible.
const expected = [
  ['explicit-pdf-before-image', 'google/pdf-custom', ['anthropic/second', 'google/pdf-custom']],
  ['explicit-image-before-auto', 'openai/vision-one', ['google/vision-two'], 32100],
  ['explicit-bare-configured-image-ref', 'custom/Vision-Exact'],
  ['native-primary-configured-model', 'anthropic/native-chosen', ['google/gemini-chosen', 'openai/vision-chosen']],
  ['native-primary-beats-priority', 'google/g', ['anthropic/a']],
  ['native-before-generic-with-manifest-defaults', 'anthropic/claude-opus-5-5', ['google/gemini-3-flash-preview', 'openai/gpt-6-astra']],
  ['native-default-dedup-current-active', 'anthropic/claude-opus-5-5', ['google/gemini-3-flash-preview']],
  ['configured-custom-vision-order', 'custom/vision-first', ['other/other-image']],
  ['configured-self-prefixed-vision-no-double-prefix', 'custom/vision-one', ['custom/custom/vision-one']],
  ['primary-text-before-generic', 'minimax/text-primary', ['openai/vision']],
  ['native-before-primary-text', 'anthropic/native', ['minimax/text-primary']],
  ['document-text-default-without-configured-text', 'openai/vision', ['minimax/MiniMax-M2.7']],
  ['minimax-cn-execution-alias-text', 'minimax-cn/text-china'],
  ['active-fills-final-no-prior-primary', 'custom/active/with/slashes'],
  ['active-self-prefixed-ref-kept', 'custom/active'],
  ['nonprimary-minimax-first-configured-text', 'openai/vision', ['minimax/text-first']],
  ['primary-image-default-selects-document-text-hint', 'minimax/MiniMax-M2.7', ['openai/vision']],
  ['native-group-before-tied-generic-exact-saved-refs', 'anthropic/claude-opus-5-5', ['google/gemini-3-flash-preview', 'openai/gpt-6-astra']],
];

test('full original selector returns all eighteen independent ordered literal outputs', () => {
  assert.equal(receipt.status, 'PASS');
  assert.equal(receipt.results.length, 18);
  assert.deepEqual(receipt.results.map(row => row.id), expected.map(row => row[0]));
  for (const [id, primary, fallbacks, timeoutMs] of expected) {
    const row = receipt.results.find(value => value.id === id);
    const value = {primary, ...(fallbacks ? {fallbacks} : {}), ...(timeoutMs ? {timeoutMs} : {})};
    assert.deepEqual(row.actual, value, id);
    assert.deepEqual(row.expected, value, id);
    assert.equal(row.pass, true);
  }
});

test('all forty-nine source modules and one hundred seventy-four manifests have exact current bytes', () => {
  assert.equal(receipt.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(receipt.wholeModules.length, 49);
  assert.equal(receipt.manifests.length, 174);
  for (const row of [...receipt.wholeModules, ...receipt.manifests]) {
    assert.equal(row.sha256, hash(readFileSync(join(root, row.path))), row.path);
  }
  for (const row of receipt.wholeModules) {
    assert.equal(row.wholeModule, true);
    assert.equal(row.evaluationStatus, 'evaluated');
  }
  for (const source of ['src/agents/tools/pdf-tool.model-config.ts', 'src/media-understanding/defaults.ts',
    'src/media-understanding/provider-registry-metadata.ts', 'src/media-understanding/config-provider-models.ts',
    'src/agents/tools/image-tool.helpers.ts', 'src/agents/tools/model-config.helpers.ts']) {
    assert.ok(receipt.wholeModules.some(row => row.path === source));
    assert.ok(!receipt.boundaries.some(row => row.path === source));
  }
});

test('only declared manifest and availability ports execute; sealed imports remain uncalled', () => {
  assert.equal(receipt.boundaries.length, 52);
  const ports = receipt.boundaries.filter(row => row.kind === 'explicit-fixture-port');
  const sealed = receipt.boundaries.filter(row => row.kind === 'sealed-uninvoked-import');
  assert.equal(ports.length, 12);
  assert.equal(sealed.length, 39);
  assert.deepEqual(receipt.boundaries.filter(row => row.kind === 'node-platform-module').map(row => row.path), ['node:path']);
  assert.equal(receipt.calls.length, 1514);
  for (const call of receipt.calls) {
    assert.ok(ports.some(row => row.path === call.source && row.names.includes(call.name)), call.source);
    assert.ok(!sealed.some(row => row.path === call.source));
  }
  for (const binding of receipt.bindings) {
    assert.ok([...receipt.wholeModules, ...receipt.boundaries].some(row => row.path === binding.target));
  }
});

test('checkout bytes modes and symlinks remain pinned and complete fixture reproduces', () => {
  assert.equal(receipt.sourceBefore.count, 58558);
  assert.deepEqual(receipt.sourceAfter, receipt.sourceBefore);
  assert.deepEqual(receipt, frozen);
});
