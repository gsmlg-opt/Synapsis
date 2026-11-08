// Complete pinned native PDF helper; all imported services are explicit fixtures.
// This captures ordinary successful request content, with no provider connection.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const PDF_NATIVE_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
export const PDF_NATIVE_SOURCE = 'src/agents/tools/pdf-native-providers.ts';
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));

// These are byte tokens, not parsable PDF documents. The reference helper only
// forwards base64; the host consumer substitutes bytes of real local PDF files.
function inputs() {
  const first = { base64: Buffer.from('%PDF-1.7\nreference-first\n%%EOF\n').toString('base64') };
  const second = { base64: Buffer.from('%PDF-1.7\nreference-second\n%%EOF\n').toString('base64') };
  const anthropic = { content: [{ type: 'text', text: ' First PDF' }, { type: 'text', text: ' analysis. ' }] };
  const gemini = { candidates: [{ content: { parts: [{ text: ' First PDF' }, { text: ' analysis. ' }] } }] };
  return [
    { id: 'anthropic-one', protocol: 'anthropic',
      input: { pdfs: [first], prompt: 'Summarize this PDF.', modelId: 'claude-sonnet-4-6' }, response: anthropic },
    { id: 'anthropic-two', protocol: 'anthropic', input: { pdfs: [first, second],
      prompt: 'Compare these PDFs in order.', modelId: 'claude-sonnet-4-6', maxTokens: 2048,
      baseUrl: 'http://127.0.0.1:18181/anthropic/v1/' }, response: anthropic },
    { id: 'gemini-one', protocol: 'google',
      input: { pdfs: [first], prompt: 'Summarize this PDF.', modelId: 'gemini-2.5-pro' }, response: gemini },
    { id: 'gemini-two', protocol: 'google', input: { pdfs: [first, second],
      prompt: 'Compare these PDFs in order.', modelId: 'gemini-2.5-pro',
      baseUrl: 'http://127.0.0.1:18181/google/v1beta/' }, response: gemini },
    { id: 'gemini-model-escape', protocol: 'google', input: { pdfs: [first],
      prompt: 'Summarize this PDF.', modelId: 'publisher/model beta',
      baseUrl: 'http://127.0.0.1:18181/google/v1beta' }, response: gemini },
  ];
}

const boundaryDescriptions = {
  '@openclaw/ai/internal/anthropic': {
    buildAnthropicClaudeCodeIdentity: 'unused identity service outside the ordinary fixture path',
    buildAnthropicSystemBlocks: 'returns undefined for the fixture with no system prompt',
    isAnthropicOAuthApiKey: 'fixed ordinary provider-key fixture branch; classifier unexecuted',
  },
  '@openclaw/ai/transports': {
    resolveAnthropicMessagesUrl: 'fixture URL resolver strips trailing slashes and appends /messages after /v1',
  },
  '../../llm/ai-transport-host.js': {},
  '../../infra/http-error-body.js': {
    readResponseBodySnippet: 'unused error body service',
  },
  '../../media-understanding/shared.js': {
    postJsonRequest: 'records serialized request content and returns a synthetic successful Response; release counted; no sockets or timer',
    readProviderJsonResponse: 'uses fixture Response.json; production bounded parser unexecuted',
    resolveProviderHttpRequestConfigWithOriginTrust: 'fixture selects supplied/default base URL, strips trailing slashes, and builds Headers; production request configuration unexecuted',
  },
  '../../plugins/provider-runtime.js': {
    normalizeProviderTransportWithPlugin: 'returns supplied base URL; plugin discovery/normalization unexecuted',
  },
  '../../utils.js': { isRecord: 'fixture plain non-array object predicate' },
  '../../utils/normalize-secret-input.js': {
    normalizeSecretInput: 'passes the explicit synthetic string through; production secret normalization unexecuted',
  },
  '../provider-http-errors.js': {
    createProviderErrorTextRedactor: 'returns identity function; no error text used',
  },
  '../provider-network-policy.js': {
    resolveProviderTransportSsrFPolicy: 'returns undefined at synthetic HTTP boundary; production network classifier unexecuted',
  },
  '../provider-secret-egress.js': {
    unwrapSecretSentinelsForProviderEgress: 'passes synthetic fixture header string through; production secret egress unexecuted',
  },
};

class PdfNativeCapture {
  constructor(executable, recipe) {
    this.recipe = recipe;
    this.requests = [];
    this.releaseCount = 0;
    this.calls = [];
    this.modules = new Map();
    this.context = vm.createContext({ Headers, fetch: async () => {
      throw Error('Capture only uses the synthetic HTTP binding');
    } }, { codeGeneration: { strings: false, wasm: false } });
    this.module = new vm.SourceTextModule(executable, {
      context: this.context, identifier: PDF_NATIVE_SOURCE,
    });
  }

  import(specifier) {
    assert.ok(Object.hasOwn(boundaryDescriptions, specifier), `declared platform import: ${specifier}`);
    if (this.modules.has(specifier)) return this.modules.get(specifier);
    const called = (name, value) => {
      this.calls.push({ module: specifier, export: name });
      return value;
    };
    const unused = () => { throw Error('Unused platform service invoked'); };
    const bindings = {
      buildAnthropicClaudeCodeIdentity: unused,
      buildAnthropicSystemBlocks: () => called('buildAnthropicSystemBlocks', undefined),
      isAnthropicOAuthApiKey: () => called('isAnthropicOAuthApiKey', false),
      resolveAnthropicMessagesUrl: baseUrl => {
        const base = (baseUrl ?? 'https://api.anthropic.com').replace(/\/+$/, '');
        return called('resolveAnthropicMessagesUrl', base.endsWith('/v1') ? `${base}/messages` : `${base}/v1/messages`);
      },
      readResponseBodySnippet: unused,
      postJsonRequest: async params => {
        called('postJsonRequest');
        this.requests.push({ url: params.url, body: plain(params.body), timeoutMs: params.timeoutMs });
        return { response: Response.json(this.recipe.response), release: async () => {
          this.releaseCount += 1;
          called('release');
        } };
      },
      readProviderJsonResponse: async response => {
        called('readProviderJsonResponse');
        return response.json();
      },
      resolveProviderHttpRequestConfigWithOriginTrust: params => called('resolveProviderHttpRequestConfigWithOriginTrust', {
        baseUrl: (params.baseUrl ?? params.defaultBaseUrl).replace(/\/+$/, ''),
        headers: new Headers(params.defaultHeaders),
      }),
      normalizeProviderTransportWithPlugin: params => called('normalizeProviderTransportWithPlugin', { baseUrl: params.context.baseUrl }),
      isRecord: value => called('isRecord', typeof value === 'object' && value !== null && !Array.isArray(value)),
      normalizeSecretInput: value => called('normalizeSecretInput', value),
      createProviderErrorTextRedactor: () => called('createProviderErrorTextRedactor', value => value),
      resolveProviderTransportSsrFPolicy: () => called('resolveProviderTransportSsrFPolicy', undefined),
      unwrapSecretSentinelsForProviderEgress: value => called('unwrapSecretSentinelsForProviderEgress', value),
    };
    const names = Object.keys(boundaryDescriptions[specifier]);
    const module = new vm.SyntheticModule(names, function () {
      for (const name of names) this.setExport(name, bindings[name]);
    }, { context: this.context, identifier: specifier });
    this.modules.set(specifier, module);
    return module;
  }

  async run() {
    await this.module.link(specifier => this.import(specifier));
    await this.module.evaluate({ timeout: 2000 });
    const name = this.recipe.protocol === 'anthropic' ? 'anthropicAnalyzePdf' : 'geminiAnalyzePdf';
    const result = await this.module.namespace[name]({ apiKey: 'fixture-provider-key', ...plain(this.recipe.input) });
    assert.equal(this.requests.length, 1);
    assert.equal(this.releaseCount, 1);
    return { ...plain(this.recipe), export: name, request: this.requests[0], result,
      releaseCount: this.releaseCount, platformCalls: this.calls };
  }
}

export async function runPdfNativeCapture(root = '/tmp/openclaw-488631c') {
  assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), PDF_NATIVE_PIN);
  const bytes = readFileSync(join(root, PDF_NATIVE_SOURCE));
  const original = execFileSync('git', ['show', `${PDF_NATIVE_PIN}:${PDF_NATIVE_SOURCE}`], { cwd: root });
  assert.deepEqual(bytes, original, 'complete helper bytes match pinned git object');
  const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
  const observations = [];
  for (const recipe of inputs()) observations.push(await new PdfNativeCapture(executable, recipe).run());
  return {
    schemaVersion: 1, referencePin: PDF_NATIVE_PIN,
    harness: { path: 'scripts/openclaw/capture-pdf-native.mjs', sha256: hash(readFileSync(new URL(import.meta.url))) },
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    sourceAudit: [{ path: PDF_NATIVE_SOURCE, sourceSha256: hash(bytes), executableSha256: hash(executable), wholeModule: true, executed: true }],
    platformBoundaries: Object.entries(boundaryDescriptions).map(([module, exports]) => ({ module, originalSourceExecuted: false, exports })),
    limits: [
      'Only the complete pdf-native-providers.ts source executes; every import is a synthetic platform module, including the side-effect transport host.',
      'Synthetic successful HTTP responses are local bindings with no live network or real provider validation.',
      '120000 ms is the timeout argument observed from the source; deadline execution and production resource lifetime are unverified.',
      'Input base64 encodes synthetic PDF byte tokens; host Gaoxy consumers substitute actual local PDF file bytes, prompt and configured model.',
      'Anthropic URL resolution and generic trailing-slash base URL normalization are supplied fixtures, not executed upstream implementations.',
      'Gemini helper emits inline_data/mime_type; host official codec emits inlineData/mimeType. Consumers normalize only these content keys for comparison.',
      'The reference uses one-shot JSON HTTP; the host uses provider streaming. Comparison establishes PDF/text content branch behavior, not complete transport parity.',
      'Imported provider configuration, identity, secret, redaction, plugin and network classification services are fixture boundaries, with no production policy claims.',
    ],
    observations,
  };
}

export async function writePdfNativeCapture(root, output) {
  const capture = await runPdfNativeCapture(root);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  return capture;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', output] = process.argv.slice(2);
  if (output) await writePdfNativeCapture(root, output);
  else process.stdout.write(JSON.stringify(await runPdfNativeCapture(root), null, 2) + '\n');
}
