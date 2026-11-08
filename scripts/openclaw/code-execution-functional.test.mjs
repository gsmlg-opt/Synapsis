// Ordinary positive fixed-source oracle; no Synapsis implementation imports.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { captureCodeExecution } from './capture-code-execution.mjs';

const root = process.env.OPENCLAW_CODE_EXECUTION_SOURCE ?? '/tmp/openclaw-488631c';
const fixture = process.env.OPENCLAW_CODE_EXECUTION_FIXTURE
  ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/code-execution.json', import.meta.url);
const capture = await captureCodeExecution(root);
const digest = value => createHash('sha256').update(value).digest('hex');
const group = id => { const value = capture.groups.find(row => row.id === id); assert.ok(value, id); return value; };
const first = id => group(id).steps[0];
const result = id => first(id).result;
const task = 'Calculate totals for the supplied data';
const url = n => `https://analysis.example/source/${n}`;

test('complete factory, config normalizer, request/parser/model compat and TypeBox have exact byte provenance', () => {
  assert.equal(capture.pin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  assert.equal(capture.runtime, 'v24.22.1');
  assert.equal(capture.checkout.before.verifiedTrackedFiles, 58_558);
  assert.equal(capture.checkout.before.verified, true);
  assert.deepEqual(capture.checkout.before, capture.checkout.after);
  assert.equal(capture.typebox.version, '1.3.37');
  for (const key of ['fullSourceModules', 'factoryInvoked', 'publicCallbackInvoked', 'actualJsonResult', 'noCache',
    'actualResponsesBuilder', 'actualResponseProjection', 'actualModelCompat', 'actualPluginConfigNormalization']) assert.equal(capture.boundaries[key], true, key);
  for (const key of ['bodyProjections', 'pluginRegistrationInvoked', 'productionNetworkInvoked']) assert.equal(capture.boundaries[key], false, key);
  for (const path of ['extensions/xai/code-execution.ts', 'extensions/xai/code-execution-tool-shared.ts',
    'extensions/xai/src/code-execution-shared.ts', 'extensions/xai/src/code-execution-config.ts',
    'extensions/xai/src/responses-tool-shared.ts', 'extensions/xai/src/tool-config-shared.ts',
    'extensions/xai/model-definitions.ts', 'extensions/xai/model-id.ts', 'extensions/xai/model-compat.ts',
    'extensions/xai/runtime-model-compat.ts', 'src/plugins/provider-model-compat.ts',
    'src/plugin-sdk/plugin-config-runtime.ts', 'src/config/runtime-config-capture-state.ts',
    'src/plugins/config-state.ts', 'src/plugins/config-normalization-shared.ts',
    'src/agents/tools/common.ts', 'src/agents/tools/tool-results.ts', 'src/agents/tools/web-search-provider-common.ts']) {
    assert.equal(capture.sources.find(row => row.path === path)?.executed, true, path);
  }
  for (const row of capture.sources) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(row.sourceSha256, digest(bytes), row.path);
    assert.equal(row.executableSha256, digest(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    assert.equal(row.wholeModule, true);
  }
  assert.equal(capture.counts.executedWholeModules, capture.sources.filter(row => row.executed).length);
  assert.equal(capture.counts.provenanceOnlyModules, capture.sources.filter(row => !row.executed).length);
  for (const row of capture.facades) assert.equal(row.sha256, digest(row.generatedCode));
  for (const row of [capture.manifest, capture.license]) assert.equal(row.sha256, digest(readFileSync(join(root, row.path))));
  assert.deepEqual(capture.manifest.content, JSON.parse(readFileSync(join(root, capture.manifest.path), 'utf8')));
  assert.equal(capture.license.text, readFileSync(join(root, 'LICENSE'), 'utf8'));
  assert.equal(capture.harness.sha256, digest(readFileSync(new URL('./capture-code-execution.mjs', import.meta.url))));
  for (const row of capture.harnessDependencies) assert.equal(row.sha256, digest(readFileSync(new URL('../../' + row.path, import.meta.url))));
  let typeboxRoot = dirname(realpathSync(createRequire(join(root, 'package.json')).resolve('typebox')));
  while (!existsSync(join(typeboxRoot, 'package.json'))) typeboxRoot = dirname(typeboxRoot);
  for (const row of capture.typebox.files) assert.equal(row.sha256, digest(readFileSync(join(typeboxRoot, row.path.slice('typebox/'.length)))));
  assert.ok(capture.typebox.files.length > 300);
});

test('actual factory declares only the full remote analysis task', () => {
  const { descriptor } = group('basic-default');
  assert.equal(descriptor.name, 'code_execution'); assert.equal(descriptor.label, 'Code Execution');
  assert.equal(descriptor.description, 'Run sandboxed Python analysis with xAI. Use for calculations, tabulation, summaries, and chart-style analysis without local machine access.');
  assert.deepEqual(descriptor.parameters, {
    type: 'object', required: ['task'], properties: { task: { type: 'string',
      description: "The full analysis task for xAI's remote Python sandbox. Include any data to analyze directly in the task." } },
  });
  for (const row of capture.groups) assert.deepEqual(row.descriptor, descriptor);
});

test('actual builder emits remote code interpreter defaults, normalized task and exact successful wire', () => {
  const body = { model: 'grok-4.7', input: [{ role: 'user', content: task }], tools: [{ type: 'code_interpreter' }],
    store: false, reasoning: { effort: 'low' } };
  assert.deepEqual(first('basic-default').request.body, body);
  assert.equal(first('basic-default').request.url, 'https://api.x.ai/v1/responses');
  assert.equal(first('basic-default').request.timeoutSeconds, 30);
  assert.deepEqual(first('full-config').request.body, { ...body, max_turns: 4 });
  assert.equal(first('full-config').request.timeoutSeconds, 17.5);
  assert.equal(first('web-base-does-not-select-endpoint').request.url, 'https://api.x.ai/v1/responses');
  assert.equal(first('ordinary-data-task').request.body.input[0].content, 'Total this CSV:\nitem,value\nalpha,12\nbeta,30');
  for (const row of capture.groups) for (const step of row.steps) {
    assert.equal(step.request.method, 'POST'); assert.equal(step.request.url, 'https://api.x.ai/v1/responses');
    assert.deepEqual(step.request.headers, { accept: 'application/json', authorization: 'Bearer fixture-code-execution-key', 'content-type': 'application/json' });
    assert.deepEqual(JSON.parse(step.request.bodyText), step.request.body);
  }
});

test('actual runtime plugin configuration precedes source with source fallback when absent', () => {
  const runtime = first('runtime-config-precedence');
  assert.equal(runtime.request.body.model, 'grok-4.3');
  assert.deepEqual(runtime.request.body.reasoning, { effort: 'low' });
  assert.equal(runtime.request.body.max_turns, 2); assert.equal(runtime.request.timeoutSeconds, 11);
  const source = first('source-config-fallback');
  assert.equal(source.request.body.model, 'grok-4.3'); assert.equal(source.request.body.max_turns, 3);
  assert.equal(source.request.timeoutSeconds, 19);
});

test('actual model aliases and low-preferred reasoning compatibility match code execution semantics', () => {
  const expected = {
    'grok-4.3': ['grok-4.3', 'low'], 'grok-4.3-latest': ['grok-4.3', 'low'],
    'grok-latest': ['grok-latest', undefined], 'grok-4.5': ['grok-4.5', undefined],
    'grok-4.5-latest': ['grok-4.5', undefined], 'grok-4.6': ['grok-4.6', 'low'],
    'grok-4.7': ['grok-4.7', 'low'], 'grok-4.7-latest': ['grok-4.7', 'low'],
    'grok-4.20': ['grok-4.20', undefined], 'grok-4-fast': ['grok-4-fast', undefined],
    'grok-5': ['grok-5', 'low'], 'grok-4.8-0115': ['grok-4.8-0115', 'low'],
    'grok-code-fast-1': ['grok-build-0.1', undefined], 'grok-build-latest': ['grok-4.5', undefined],
    'grok-4-fast-reasoning': ['grok-4-fast', undefined],
  };
  for (const [name, [model, effort]] of Object.entries(expected)) {
    const step = first('model-' + name);
    assert.equal(step.request.body.model, model); assert.equal(step.result.model, model);
    assert.deepEqual(step.request.body.reasoning, effort ? { effort } : undefined);
  }
});

test('actual repeated identical tasks each perform a new remote request with no cache', () => {
  const steps = group('same-task-no-cache').steps;
  assert.deepEqual(steps.map(step => step.cumulativeRequests), [1, 2, 3]);
  for (const step of steps) {
    assert.deepEqual(step.arguments, steps[0].arguments); assert.deepEqual(step.result, steps[0].result);
    assert.equal('cached' in step.result, false);
  }
});

test('actual output text concatenates blocks before fallback and preserves ordinary whitespace', () => {
  assert.equal(result('adjacent-blocks').content, 'First Second😀 Third');
  assert.equal(result('direct-output-text').content, 'Direct answer');
  assert.equal(result('output-text-fallback').content, ' Fallback answer 😀 ');
  assert.equal(result('message-before-fallback').content, 'Block answer');
  assert.equal(result('whitespace-answer').content, ' \t\n ');
  assert.deepEqual(result('basic-default'), { task, provider: 'xai', model: 'grok-4.7', tookMs: 7,
    content: ' Ordinary analysis 😀 \n', citations: [url(1)], usedCodeExecution: true, outputTypes: ['code_interpreter_call', 'message'] });
});

test('actual ordered unique output types identify reported interpreter use without local execution', () => {
  assert.deepEqual(result('ordered-output-types').outputTypes, ['reasoning', 'code_interpreter_call', 'message']);
  assert.equal(result('ordered-output-types').usedCodeExecution, true);
  assert.deepEqual(result('message-output-type').outputTypes, ['message']); assert.equal(result('message-output-type').usedCodeExecution, false);
  assert.deepEqual(result('output-text-fallback').outputTypes, []); assert.equal(result('output-text-fallback').usedCodeExecution, false);
  assert.deepEqual(result('direct-output-text').outputTypes, ['output_text']); assert.equal(result('direct-output-text').usedCodeExecution, false);
});

test('actual citations retain top-level precedence, normalized order, twenty count and thousand scan bounds', () => {
  assert.deepEqual(result('top-citation-precedence').citations, [url(1), url(3)]);
  assert.deepEqual(result('annotation-citation-order').citations, [url(2), url(1)]);
  assert.deepEqual(result('citation-canonical-url').citations,
    ['https://analysis.example/path%20with%20space?q=ordinary%20text#part', 'https://bare.example']);
  assert.deepEqual(result('twenty-citations').citations, Array.from({ length: 20 }, (_, n) => url(n)));
  assert.deepEqual(result('citation-thousand-scan').citations, [url(1)]);
  assert.deepEqual(result('annotation-thousand-scan').citations, [url(1)]);
  assert.equal(result('citation-exact-url-budget').citations[0].length, 2_048);
});

test('actual analysis has no twenty-thousand text cap and keeps later block citations', () => {
  assert.equal(result('long-ascii-no-cap').content, 'A'.repeat(25_001));
  assert.equal(result('long-unicode-fallback-no-cap').content, '😀'.repeat(10_001) + 'e\u0301👩‍💻');
  assert.equal(result('long-adjacent-no-cap').content, 'A'.repeat(12_000) + 'B'.repeat(12_001));
  assert.deepEqual(result('long-adjacent-no-cap').citations, [url(7)]);
  for (const name of ['long-ascii-no-cap', 'long-unicode-fallback-no-cap', 'long-adjacent-no-cap']) {
    assert.equal(result(name).content.isWellFormed(), true); assert.ok(result(name).content.length > 20_000);
  }
  assert.equal('inlineCitations' in result('inline-input-not-public-output'), false);
});

test('original complete JSON result is retained with immutable input and identity portable map', () => {
  for (const row of capture.groups) for (const step of row.steps) {
    assert.deepEqual(step.arguments, step.argumentsAfter); assert.deepEqual(step.config, step.configAfter);
    assert.deepEqual(step.runtimeConfig, step.runtimeConfigAfter);
    assert.deepEqual(step.toolResult, { content: [{ type: 'text', text: JSON.stringify(step.result, null, 2) }], details: step.result });
    assert.deepEqual(step.resultPortable, step.result);
    for (const key of ['externalContent', 'truncated', 'cached', 'inlineCitations']) assert.equal(key in step.result, false);
    assert.deepEqual(Object.keys(step.result), ['task', 'provider', 'model', 'tookMs', 'content', 'citations', 'usedCodeExecution', 'outputTypes']);
  }
});

test('fresh complete capture equals frozen source fixture', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixture, 'utf8')));
});
