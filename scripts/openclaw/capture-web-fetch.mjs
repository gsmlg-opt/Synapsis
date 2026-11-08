// Whole pinned ordinary web_fetch callbacks. Network/registry services are explicit
// successful fixtures; this does not qualify OpenClaw's network guard or assembly.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, hash as cryptoHash, randomUUID } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

export const WEB_FETCH_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const factory = 'src/agents/tools/web-fetch.ts';
const norm = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const from = (names, path) => `export {${names}} from ${JSON.stringify('source:' + path)};`;
const clock = '2026-11-08T04:00:00.000Z';
const markdown = '# A page\n\nAn ordinary [link](https://links.example/page) and `code`.\n\n- First\n- Second\n';
const paragraph = 'The observatory records the changing sky each evening. Its observers compare careful measurements with earlier records, discuss the results, and publish a clear account for other readers. ';
const article = '<!doctype html><html><head><title>Observatory journal</title></head><body><nav>Navigation</nav><article><h1>Observatory journal</h1><p>'
  + paragraph.repeat(4) + '</p><p>The next observation includes <a href="https://links.example/records">published records</a>.</p></article><footer>Contact</footer></body></html>';

export function webFetchVectors() {
  return [
    { id: 'plain', contentType: 'text/plain; charset=utf-8', body: 'Ordinary café 😀.\n' },
    { id: 'markdown', contentType: 'text/markdown; charset=utf-8', body: markdown },
    { id: 'markdown-text', contentType: 'text/markdown', body: markdown, args: { extractMode: 'text' } },
    { id: 'article', contentType: 'text/html', body: article },
    { id: 'article-text', contentType: 'application/xhtml+xml', body: article, args: { extractMode: 'text' } },
    { id: 'json', contentType: 'application/json', body: '{"integer":9007199254740993,"decimal":1.2300,"exponent":1e+30,"zero":-0}' },
    { id: 'json-subtype', contentType: 'application/ld+json; charset=utf-8', body: '{"n":123456789012345678901234567890,"items":[1e-40,2.00]}' },
    { id: 'declared-charset', contentType: 'text/plain; charset=windows-1252', bytes: [67,97,102,233,32,128] },
    { id: 'bom', contentType: 'text/plain', bytes: [255,254,67,0,97,0,102,0,233,0] },
    { id: 'document-charset', contentType: 'text/html', body: '<html><head><meta charset="windows-1252"><title>Café journal</title></head><body><article><p>' + paragraph.repeat(4) + ' Café.</p></article></body></html>', encoding: 'latin1' },
    { id: 'final-url', contentType: 'text/plain', body: 'Destination content.', finalUrl: 'https://destination.example/final?q=page' },
    { id: 'repeat-cache', contentType: 'text/plain', body: 'Cached original body.', repeat: 2 },
    { id: 'provider-success', contentType: 'text/html', body: article, config: { readability: false }, provider: {
      finalUrl: 'https://rendered.example/page', status: 200, contentType: 'text/markdown', title: 'Rendered page',
      extractor: 'fixture-provider', text: 'Ordinary provider content.', fetchedAt: clock, tookMs: 12,
    } },
  ];
}

class FetchCapture {
  constructor(root, dependencyRoot) {
    this.root = realpathSync(root);
    this.dependencyRoot = realpathSync(dependencyRoot);
    this.modules = new Map(); this.sources = new Map(); this.facades = new Map();
    this.edges = [];
    this.bindings = []; this.audit = []; this.requests = []; this.packages = new Map();
    this.now = Date.parse(clock);
    const owner = this;
    class FixtureDate extends Date {
      constructor(...args) { super(...(args.length ? args : [owner.now])); }
      static now() { return owner.now; }
    }
    this.context = vm.createContext({ Date: FixtureDate, URL, Headers, Response, Buffer,
      TextDecoder, TextEncoder, AbortController, setTimeout, clearTimeout, process: { env: {} } });
  }

  source(path) {
    assert.ok(!path.startsWith('../') && !path.startsWith('/') && path.endsWith('.ts'), path);
    const id = 'source:' + path;
    if (!this.modules.has(id)) {
      const bytes = readFileSync(join(this.root, path));
      const pinned = execFileSync('git', ['show', `${WEB_FETCH_PIN}:${path}`], { cwd: this.root });
      assert.deepEqual(bytes, pinned, path);
      const code = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      this.sources.set(path, { path, sourceSha256: hash(bytes), executableSha256: hash(code), wholeModule: true });
      this.modules.set(id, new vm.SourceTextModule(code, { context: this.context, identifier: id,
        importModuleDynamically: async specifier => {
          const mod = await this.link(specifier, id);
          await this.evaluate(mod);
          return mod;
        } }));
    }
    return this.modules.get(id);
  }

  synthetic(id, values, description) {
    if (!this.modules.has(id)) {
      this.bindings.push({ id, description, exports: Object.keys(values).sort() });
      this.modules.set(id, new vm.SyntheticModule(Object.keys(values), function () {
        for (const [name, value] of Object.entries(values)) this.setExport(name, value);
      }, { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }

  facade(id, code) {
    if (!this.modules.has(id)) {
      this.facades.set(id, { id, code, sha256: hash(code) });
      this.modules.set(id, new vm.SourceTextModule(code, { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }

  unused(path, names) {
    return this.synthetic('unused:' + path, Object.fromEntries(names.map(name => [name, () => {
      this.audit.push({ kind: 'unexpected-service', path, name });
      throw Error('Unqualified service invoked: ' + path + ':' + name);
    }])), 'Throwing unexecuted service edge; no qualification of this service.');
  }

  async dependency(specifier) {
    const typebox = specifier === 'typebox';
    const req = createRequire(join(typebox
      ? '/tmp/synapsis-openclaw-capture-runtime' : this.dependencyRoot, 'package.json'));
    let entry = realpathSync(req.resolve(specifier === 'linkedom/worker' ? 'linkedom' : specifier));
    let root = dirname(entry);
    while (!existsSync(join(root, 'package.json'))) root = dirname(root);
    // linkedom/worker is in its package root; nested entities files use exports.
    let manifest = JSON.parse(readFileSync(join(root, 'package.json')));
    while (!manifest.name) {
      root = dirname(root); manifest = JSON.parse(readFileSync(join(root, 'package.json')));
    }
    if (specifier === 'linkedom/worker') entry = join(root, 'worker.js');
    const expected = { typebox: '1.3.37', '@mozilla/readability': '0.6.0', linkedom: '0.18.13', entities: '8.1.0' };
    assert.equal(manifest.version, expected[manifest.name], manifest.name);
    if (!this.packages.has(manifest.name)) {
      const files = readdirSync(root, { recursive: true, withFileTypes: true })
        .filter(row => row.isFile()).map(row => {
          const file = join(row.parentPath, row.name);
          return { path: relative(root, file), sha256: hash(readFileSync(file)) };
        }).sort((a, b) => a.path.localeCompare(b.path));
      this.packages.set(manifest.name, { name: manifest.name, version: manifest.version, root, files });
    }
    const namespace = await import(pathToFileURL(entry));
    return this.synthetic('dependency:' + specifier, namespace, 'Actual installed package namespace, exact version and file hashes recorded.');
  }

  async link(specifier, importer) {
    const mod = await this.resolveImport(specifier, importer);
    this.edges.push({ importer, specifier, target: mod.identifier });
    return mod;
  }

  async resolveImport(specifier, importer) {
    if (specifier.startsWith('source:')) return this.source(specifier.slice(7));
    if (['typebox', '@mozilla/readability', 'linkedom/worker', 'entities'].includes(specifier)) return this.dependency(specifier);
    if (specifier === 'node:crypto') return this.synthetic(specifier,
      { createHash, hash: cryptoHash, randomUUID, randomBytes: size => Buffer.alloc(size, 0x36) }, 'Native crypto; fixed wrapper-marker randomBytes only.');
    if (specifier === 'node:buffer') return this.synthetic(specifier, { Buffer }, 'Native Buffer.');
    if (specifier.startsWith('@openclaw/normalization-core/')) return this.source(norm + specifier.split('/').at(-1) + '.ts');
    if (specifier === '@openclaw/normalization-core') return this.facade(specifier,
      from('consumeResponseBytes', norm + 'response-bytes.ts') + from('decodeTextPrefix', norm + 'text-decoding.ts'));
    if (specifier === sdk + 'lazy-runtime') return this.source('src/shared/lazy-runtime.ts');
    if (specifier === sdk + 'web-content-extractor') return this.source('src/plugin-sdk/web-content-extractor.ts');
    if (specifier === '@openclaw/media-core/mime') return this.unused(specifier, ['detectMime']);
    assert.ok(specifier.startsWith('.'), `${importer} -> ${specifier}`);
    const parent = importer.slice(7);
    const path = relative(this.root, resolve(this.root, dirname(parent), specifier)).replace(/\.js$/, '.ts');
    const unused = {
      'src/infra/fs-safe.ts': ['readLocalFileSafely'],
      'src/agents/sessions/tools/private-temp-file.ts': ['writePrivateTempFile'],
      'src/agents/sessions/tools/tool-contracts.ts': ['formatFullOutputFooter'],
    };
    if (unused[path]) return this.unused(path, unused[path]);
    if (path === 'src/infra/crypto-digest.ts') return this.source(norm + 'node-crypto.ts');
    if (path === 'src/utils.ts') return this.facade(path, from('isRecord', norm + 'record-coerce.ts'));
    if (path === 'src/web/provider-runtime-shared.ts') return this.synthetic(path, {
      resolveWebProviderConfig: (config, kind) => config?.tools?.web?.[kind],
    }, 'Literal explicit tools.web config selection; provider registry/config assembly unexecuted.');
    if (path === 'src/agents/tools/web-tool-runtime-context.ts') return this.synthetic(path, {
      resolveWebToolRuntimeContext: params => ({ config: params.config, preferRuntimeProviders: true, providerSelectionId: '', runtimeMetadata: undefined }),
    }, 'Explicit constructor config, no late binding or selected provider owner; runtime selection unexecuted.');
    if (path === 'src/plugins/web-content-extractors.runtime.ts') {
      return this.synthetic(path, { resolvePluginWebContentExtractors: () => [this.extractor] },
        'Fixed single actual Readability extractor; plugin discovery/eligibility/order assembly unexecuted.');
    }
    if (path === 'src/agents/tools/web-guarded-fetch.ts') return this.synthetic(path, {
      fetchWithWebToolsNetworkGuard: async params => {
        this.requests.push(plain({ url: params.url, maxRedirects: params.maxRedirects,
          timeoutSeconds: params.timeoutSeconds, init: params.init }));
        const row = this.current;
        const bytes = row.bytes ? Buffer.from(row.bytes) : Buffer.from(row.body, row.encoding ?? 'utf8');
        this.now += 7;
        return { response: new Response(bytes, { status: 200, headers: { 'content-type': row.contentType } }),
          finalUrl: row.finalUrl ?? params.url, release: async () => { this.audit.push({ kind: 'release', id: row.id }); } };
      },
    }, 'Synthetic successful Response bytes and guard-reported finalUrl; +7ms clock, observed release. No real HTTP, redirects, network guard or policy execution.');
    if (path === 'src/web-fetch/runtime.ts') return this.synthetic(path, {
      resolveWebFetchDefinition: async () => {
        assert.ok(this.current.provider);
        return { provider: { id: 'ordinary-fixture', label: 'Ordinary fixture' }, definition: { execute: async args => {
          this.audit.push({ kind: 'provider', args: plain(args) }); return this.current.provider;
        } } };
      },
    }, 'Successful explicit provider callback; provider loading, credentials and Firecrawl implementation unexecuted.');
    if (path === 'src/agents/agent-tool-source-execution-guard.ts') return this.synthetic(path,
      { captureAgentToolSourceExecutionGuard: () => () => {} }, 'Unexecuted source-invocation ownership boundary.');
    if (path === 'src/infra/net/ssrf.ts') return this.synthetic(path,
      { SsrFBlockedError: class SsrFBlockedError extends Error {} }, 'Error identity only; no security behavior executed.');
    if (path === 'src/logger.ts') return this.unused(path, ['logWarn']);
    if (path === 'src/secrets/runtime-degraded-state.ts') return this.unused(path, ['assertSecretOwnerAvailable']);
    if (path === 'src/secrets/runtime-web-secret-owner.ts') return this.unused(path, ['runtimeWebSecretOwnerId']);
    return this.source(path);
  }

  async evaluate(mod) {
    if (mod.status === 'unlinked') await mod.link((specifier, owner) => this.link(specifier, owner.identifier));
    if (mod.status === 'linked') await mod.evaluate({ timeout: 2000 });
    assert.equal(mod.status, 'evaluated', mod.identifier);
  }
}

export async function captureWebFetch(root = '/tmp/openclaw-488631c',
  dependencyRoot = '/tmp/synapsis-webfetch361-evidence/reference-runtime') {
  assert.equal(process.versions.node, '24.22.1');
  const harness = new FetchCapture(root, dependencyRoot);
  assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(), WEB_FETCH_PIN);
  const readability = harness.source('extensions/web-readability/web-content-extractor.ts');
  await harness.evaluate(readability);
  harness.extractor = readability.namespace.createReadabilityWebContentExtractor();
  const mod = harness.source(factory); await harness.evaluate(mod);
  const groups = [];
  for (const vector of webFetchVectors()) {
    harness.current = vector;
    const config = { tools: { web: { fetch: { ...vector.config } } } };
    const tool = mod.namespace.createWebFetchTool({ config });
    const args = { url: 'https://source.example/' + vector.id, ...vector.args };
    const startRequest = harness.requests.length, startAudit = harness.audit.length;
    const results = [];
    for (let index = 0; index < (vector.repeat ?? 1); index++) {
      const result = await tool.execute('ordinary-fetch-' + vector.id + '-' + index, args);
      results.push(plain(result));
      harness.now += 11;
    }
    groups.push({ id: vector.id, input: vector, args, config,
      descriptor: plain({ name: tool.name, label: tool.label, description: tool.description,
        resultContentSource: tool.resultContentSource, parameters: tool.parameters, outputSchema: tool.outputSchema }),
      results, requests: harness.requests.slice(startRequest), audit: harness.audit.slice(startAudit) });
  }
  for (const row of harness.sources.values()) assert.equal(hash(readFileSync(join(root, row.path))), row.sourceSha256);
  for (const path of ['LICENSE', 'extensions/web-readability/package.json'])
    assert.deepEqual(readFileSync(join(root, path)),
      execFileSync('git', ['show', `${WEB_FETCH_PIN}:${path}`], { cwd: root }), path);
  const unexecuted = ['network guard/HTTP/redirect traversal', 'plugin/provider discovery and eligibility',
    'late-bound configuration', 'Firecrawl provider implementation', 'spill/truncation/eviction',
    'errors/failures/cancellation/crash/recovery', 'security/permission/authentication', 'Synapsis production consumer'];
  return { pin: WEB_FETCH_PIN, runtime: process.version, factory, clock,
    boundaries: { wholeFactory: true, actualReadability: true, actualCharsetDecoder: true,
      actualExactJsonBranch: true, actualSuccessCache: true, syntheticAcquisition: true, unexecuted },
    sources: [...harness.sources.values()].sort((a, b) => a.path.localeCompare(b.path)),
    packages: [...harness.packages.values()].map(({ root: _root, ...rest }) => rest),
    facades: [...harness.facades.values()], bindings: harness.bindings,
    imports: harness.edges.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    harness: { path: 'scripts/openclaw/capture-web-fetch.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))) },
    referenceManifest: { path: 'extensions/web-readability/package.json',
      sha256: hash(readFileSync(join(root, 'extensions/web-readability/package.json'))) },
    license: { path: 'LICENSE', sha256: hash(readFileSync(join(root, 'LICENSE'))),
      text: readFileSync(join(root, 'LICENSE'), 'utf8') }, groups };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await captureWebFetch(process.argv[2], process.argv[4]);
  const output = JSON.stringify(result, null, 2) + '\n';
  if (process.argv[3]) writeFileSync(process.argv[3], output); else process.stdout.write(output);
}
