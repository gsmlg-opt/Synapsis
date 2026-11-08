// Complete unchanged pinned DuckDuckGo modules; only short successful platform fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture } from './capture-brave-search-filters.mjs';

const entrypoint = 'extensions/duckduckgo/web-search-provider.ts';
const factory = 'extensions/duckduckgo/src/ddg-search-provider.ts';
const client = 'extensions/duckduckgo/src/ddg-client.ts';
const common = 'src/agents/tools/web-search-provider-common.ts';
const readers = 'src/agents/tools/common.ts';
const shared = 'src/agents/tools/web-shared.ts';
const output = 'src/agents/tools/web-search-output.ts';
const normalization = 'packages/normalization-core/src/';
const sdk = 'openclaw/plugin-sdk/';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sorted = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const from = (names, path) => `export {${names.join(',')}} from ${JSON.stringify('capture:source:' + path)};`;
const additionalSources = new Set([entrypoint, factory, client, output, 'src/shared/html-entities.ts',
  'src/plugin-sdk/html-entity-runtime.ts', 'src/plugin-sdk/provider-web-search-contract.ts',
  'src/plugin-sdk/provider-enable-config.ts', 'src/config/plugins-allowlist.ts']);
const facades = {
  [sdk + 'provider-web-search']: [
    from(['externalContentStamp', 'DEFAULT_SEARCH_COUNT', 'readCachedSearchPayload', 'resolveSearchCount',
      'resolveSearchCacheTtlMs', 'resolveSiteName', 'writeCachedSearchPayload'], common),
    from(['resolveTimeoutSeconds'], shared),
    from(['wrapWebContent'], 'src/security/external-content.ts'),
    'export {readResponseText,withTrustedWebSearchEndpoint} from "duckduckgo:platform";',
  ].join('\n'),
  [sdk + 'provider-web-search-contract']: from(['createWebSearchProviderContractFields',
    'WEB_SEARCH_QUERY_COUNT_PROPERTIES'], 'src/plugin-sdk/provider-web-search-contract.ts'),
  [sdk + 'param-readers']: from(['readPositiveIntegerParam', 'readToolStringParam as readStringParam'], readers),
  [sdk + 'string-coerce-runtime']: [
    from(['asOptionalObjectRecord'], normalization + 'record-coerce.ts'),
    from(['normalizeOptionalString', 'normalizeLowercaseStringOrEmpty'], normalization + 'string-coerce.ts'),
  ].join('\n'),
  [sdk + 'lazy-runtime']: from(['createLazyRuntimeModule'], 'src/shared/lazy-runtime.ts'),
  [sdk + 'provider-http']: 'export {ProviderHttpError,readProviderTextResponse} from "duckduckgo:platform";',
  '@openclaw/normalization-core': [
    from(['consumeResponseBytes'], normalization + 'response-bytes.ts'),
    from(['decodeTextPrefix'], normalization + 'text-decoding.ts'),
  ].join('\n'),
};
const deferredImports = [
  [readers, '@openclaw/media-core/mime', ['detectMime'], 'packages/media-core/src/mime.ts'],
  [readers, '../../infra/fs-safe.js', ['readLocalFileSafely']],
  [readers, './tool-results.js', ['textResult', 'jsonResult']],
  [common, '../provider-http-errors.js', ['createProviderErrorTextRedactor', 'ProviderHttpError']],
  [output, '../../web-search/runtime-error.js', ['formatWebSearchNotConfiguredMessage', 'isMissingCredentialCode']],
];

function entitiesArtifact(root) {
  // Override with another existing artifact; the qualification default is the offline cached package.
  const packageRoot = realpathSync(process.env.OPENCLAW_DUCKDUCKGO_ENTITIES ??
    (existsSync(join(root, 'node_modules/entities')) ? join(root, 'node_modules/entities') :
      '/tmp/synapsis-duckduckgo321-evidence/entities-artifact/package'));
  const archive = resolve(process.env.OPENCLAW_DUCKDUCKGO_ENTITIES_TARBALL ?? join(dirname(packageRoot), 'entities-8.1.0.tgz'));
  const bytes = readFileSync(archive), lockBytes = readFileSync(join(root, 'pnpm-lock.yaml'));
  const integrity = /\n  entities@8\.1\.0:\n    resolution: \{integrity: (sha512-[^}]+)\}/.exec(lockBytes.toString())?.[1];
  assert.ok(integrity, 'pinned entities lock integrity');
  assert.equal('sha512-' + createHash('sha512').update(bytes).digest('base64'), integrity);
  const read = path => {
    const file = realpathSync(join(packageRoot, path));
    assert.ok(file.startsWith(packageRoot + sep));
    const content = readFileSync(file);
    assert.deepEqual(content, execFileSync('tar', ['-xOf', archive, 'package/' + path], { maxBuffer: 8 * 1024 * 1024 }),
      'entities module matches lock-integrity-verified package artifact: ' + path);
    return content;
  };
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.name, 'entities'); assert.equal(pkg.version, '8.1.0');
  const entry = pkg.exports['.'].default;
  assert.equal(typeof entry, 'string');
  return { packageRoot, entry, read, artifact: {
    pinnedLock: { path: 'pnpm-lock.yaml', gitBlob: blob(lockBytes), sha256: digest(lockBytes), integrity },
    tarball: { sha256: digest(bytes), sha512: createHash('sha512').update(bytes).digest('hex'), integrity },
  } };
}

class DuckDuckGoCapture extends BraveCapture {
  constructor(root, payloads, artifact) {
    super(root);
    this.payloads = payloads;
    this.entitiesArtifact = artifact;
    this.dependencies = new Map();
    this.entitiesDependencies = new Map();
    this.generatedFacades = new Map();
    this.pluginVersion = JSON.parse(readFileSync(join(root, 'extensions/duckduckgo/package.json'))).version;
    assert.equal(this.pluginVersion, '2026.10.5');
  }
  source(path) {
    if (!additionalSources.has(path)) return super.source(path);
    if (!this.modules.has(path)) this.modules.set(path, new vm.SourceTextModule(this.verifiedSource(path), {
      context: this.context, identifier: path,
      importModuleDynamically: async specifier => {
        this.audit.push({ kind: 'dynamic-import', importer: path, specifier });
        const target = this.import(specifier, path); await this.evaluate(target); return target;
      },
    }));
    return this.modules.get(path);
  }
  typeboxModule(file) {
    assert.ok(file.startsWith(this.typeboxRoot + sep));
    const id = 'duckduckgo:typebox:' + relative(this.typeboxRoot, file);
    if (!this.modules.has(id)) {
      const bytes = readFileSync(file), path = 'typebox/' + relative(this.typeboxRoot, file);
      this.dependencies.set(path, { path, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  entitiesModule(path) {
    const file = realpathSync(resolve(this.entitiesArtifact.packageRoot, path));
    path = relative(this.entitiesArtifact.packageRoot, file);
    const id = 'duckduckgo:entities:' + path;
    if (!this.modules.has(id)) {
      const bytes = this.entitiesArtifact.read(path), name = 'entities/' + path;
      this.entitiesDependencies.set(name, { path: name, sha256: digest(bytes) });
      this.modules.set(id, new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: id }));
    }
    return this.modules.get(id);
  }
  platform() {
    const bindings = {
      withTrustedWebSearchEndpoint: async (params, run) => {
        const url = new URL(params.url);
        this.audit.push({ kind: 'successful-http-fixture', url: params.url });
        const payload = this.payloads[Math.min(this.requests.length, this.payloads.length - 1)];
        this.requests.push({ url: params.url, method: params.init.method, path: url.pathname,
          query: Object.fromEntries(url.searchParams), headers: Object.fromEntries(new Headers(params.init.headers)),
          timeoutSeconds: params.timeoutSeconds, signalSupplied: params.signal !== undefined });
        this.nowMs += 7;
        return run(new Response(payload, { headers: { 'content-type': 'text/html; charset=utf-8' } }));
      },
      readProviderTextResponse: async (response, label) => {
        this.audit.push({ kind: 'successful-short-text-fixture', label });
        return response.text();
      },
      readResponseText: () => { throw Error('Unused response error text reader'); },
      ProviderHttpError: () => { throw Error('Unused provider HTTP error service'); },
    };
    const descriptions = {
      withTrustedWebSearchEndpoint: 'records complete actual GET and supplies successful short HTML Response; synthetic clock+7ms; production endpoint transport and timers unexecuted',
      readProviderTextResponse: 'successful short fixture Response.text(); actual bounded reader unexecuted',
    };
    return this.synthetic('duckduckgo:platform', bindings, Object.fromEntries(Object.keys(bindings).map(name => [name,
      { kind: descriptions[name] ? 'ordinary-platform-fixture' : 'unused-platform-service',
        behavior: descriptions[name] ?? 'throws if invoked' }])));
  }
  import(specifier, importer) {
    const link = (kind, target) => this.aliases.set(`${importer}:${specifier}`, { importer, specifier, kind, target });
    if (specifier === 'duckduckgo:platform') {
      for (const path of ['src/agents/tools/web-guarded-fetch.ts', 'src/agents/provider-http-errors.ts',
        'src/media-understanding/shared.ts']) this.verifiedSource(path, false);
      return this.platform();
    }
    if (specifier === 'node:module') {
      link('explicit-plugin-version-fixture', 'node:module');
      return this.synthetic('duckduckgo:node-module', {
        createRequire: () => {
          this.audit.push({ kind: 'plugin-require-fixture' });
          return () => { throw Error('Plugin package resolver is outside this capture'); };
        },
      }, { createRequire: { kind: 'ordinary-platform-fixture',
        behavior: 'unused require token for explicit plugin-version fixture; actual package discovery unexecuted' } });
    }
    if (specifier === sdk + 'extension-shared') {
      const path = 'src/plugin-sdk/extension-shared.ts'; this.verifiedSource(path, false);
      link('explicit-plugin-version-fixture', path);
      return this.synthetic('duckduckgo:plugin-version', {
        readPluginPackageVersion: () => {
          this.audit.push({ kind: 'plugin-version-fixture', version: this.pluginVersion });
          return this.pluginVersion;
        },
      }, { readPluginPackageVersion: { kind: 'ordinary-platform-fixture',
        behavior: 'explicit pin-verified extensions/duckduckgo/package.json version; package discovery unexecuted' } });
    }
    if (specifier === sdk + 'html-entity-runtime') {
      const path = 'src/plugin-sdk/html-entity-runtime.ts'; link('whole-module-alias', path); return this.source(path);
    }
    const deferred = deferredImports.find(([owner, name]) => owner === importer && name === specifier);
    if (deferred) {
      const path = deferred[3] ?? relative(this.root, resolve(this.root, dirname(importer), specifier)).replace(/\.js$/, '.ts');
      this.verifiedSource(path, false); link('explicit-unused-import', path);
      return this.deferred(importer, specifier, deferred[2]);
    }
    if (specifier === 'entities') {
      for (const file of ['package.json', 'LICENSE']) {
        const bytes = this.entitiesArtifact.read(file), path = 'entities/' + file;
        this.entitiesDependencies.set(path, { path, sha256: digest(bytes) });
      }
      link('actual-entities-module', 'entities/' + this.entitiesArtifact.entry.replace(/^\.\//, ''));
      return this.entitiesModule(this.entitiesArtifact.entry);
    }
    if (importer.startsWith('duckduckgo:entities:')) {
      assert.ok(specifier.startsWith('.'));
      const path = join(dirname(importer.slice('duckduckgo:entities:'.length)), specifier);
      link('actual-entities-relative-module', 'entities/' + path); return this.entitiesModule(path);
    }
    if (specifier === 'typebox') {
      const file = realpathSync(createRequire(join(this.root, 'package.json')).resolve('typebox'));
      let root = dirname(file); while (!existsSync(join(root, 'package.json'))) root = dirname(root);
      const bytes = readFileSync(join(root, 'package.json')), pkg = JSON.parse(bytes);
      assert.equal(pkg.name, 'typebox'); assert.equal(pkg.version, '1.3.37');
      this.typeboxRoot = root; this.typeboxVersion = pkg.version;
      this.dependencies.set('typebox/package.json', { path: 'typebox/package.json', sha256: digest(bytes) });
      link('actual-typebox-module', 'typebox/' + relative(root, file)); return this.typeboxModule(file);
    }
    if (importer.startsWith('duckduckgo:typebox:')) {
      assert.ok(specifier.startsWith('.'));
      return this.typeboxModule(realpathSync(resolve(this.typeboxRoot, dirname(importer.slice('duckduckgo:typebox:'.length)), specifier)));
    }
    if (facades[specifier]) {
      const provenance = specifier.startsWith(sdk) ? 'src/plugin-sdk/' + specifier.slice(sdk.length) + '.ts' : normalization + 'index.ts';
      this.verifiedSource(provenance, false);
      const generatedCode = facades[specifier], id = 'duckduckgo:facade:' + specifier;
      this.generatedFacades.set(specifier, { specifier, provenance, generatedCode, sha256: digest(generatedCode) });
      link('whole-module-re-export-or-explicit-platform-facade', id);
      if (!this.modules.has(id)) this.modules.set(id, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: id }));
      return this.modules.get(id);
    }
    return super.import(specifier, importer);
  }
}

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), BRAVE_REFERENCE_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', BRAVE_REFERENCE_PIN]).split('\0').filter(Boolean).map(entry => {
    const [header, path] = entry.split('\t'), [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob'); assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path), symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000'); assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(blob(bytes), gitBlob, path);
    return { path, gitBlob, sha256: digest(bytes) };
  });
  assert.equal(files.length, 58_558);
  return { verified: true, commit: BRAVE_REFERENCE_PIN, tree: git(root, ['rev-parse', `${BRAVE_REFERENCE_PIN}^{tree}`]),
    verifiedTrackedFiles: files.length, filesSha256: digest(JSON.stringify(files)) };
}
export function unframeDuckDuckGoSearchText(text) {
  if (text === '') return text;
  const match = /^\n<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n([\s\S]*)\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/.exec(text);
  assert.ok(match, 'exact pinned Web Search envelope'); return match[2];
}
function mapProse(value, adapt, field) {
  if (typeof value === 'string') return ['title', 'snippet', 'siteName'].includes(field) && value ? adapt(value, field) : value;
  if (Array.isArray(value)) return value.map(item => mapProse(item, adapt, field));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, mapProse(item, adapt, key)]));
  return value;
}
function recipes() {
  return [
  {
    "id": "search-default",
    "steps": [
      {
        "arguments": {
          "query": "search-default"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "authored-query",
    "steps": [
      {
        "arguments": {
          "query": " OpenClaw site:github.com \"release notes\" "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "explicit-count",
    "steps": [
      {
        "arguments": {
          "query": "ordinary explicit count",
          "count": 3
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "numeric-count-token",
    "steps": [
      {
        "arguments": {
          "query": "ordinary numeric count",
          "count": " 4 "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "configured-count",
    "steps": [
      {
        "arguments": {
          "query": "ordinary configured count"
        }
      },
      {
        "arguments": {
          "query": "ordinary configured count",
          "count": 5
        }
      },
      {
        "arguments": {
          "query": "ordinary configured count",
          "count": 3
        }
      },
      {
        "arguments": {
          "query": "ordinary configured count"
        },
        "searchConfig": {
          "maxResults": 4
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "searchConfig": {
      "maxResults": 3
    }
  },
  {
    "id": "configured-timeout",
    "steps": [
      {
        "arguments": {
          "query": "configured-timeout"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "searchConfig": {
      "timeoutSeconds": 9
    }
  },
  {
    "id": "context-search-options-ignored",
    "steps": [
      {
        "arguments": {
          "query": "ordinary context search options"
        }
      },
      {
        "arguments": {
          "query": "ordinary context search options"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "contextSearchConfig": {
      "maxResults": 3,
      "timeoutSeconds": 9,
      "cacheTtlMinutes": 0
    }
  },
  {
    "id": "configured-region",
    "steps": [
      {
        "arguments": {
          "query": "configured-region"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "providerConfig": {
      "region": " de-de "
    }
  },
  {
    "id": "argument-region",
    "steps": [
      {
        "arguments": {
          "query": "ordinary region override",
          "region": " uk-en "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "providerConfig": {
      "region": "de-de"
    }
  },
  {
    "id": "blank-region-fallback",
    "steps": [
      {
        "arguments": {
          "query": "ordinary blank region",
          "region": "  "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ],
    "providerConfig": {
      "region": " de-de "
    }
  },
  {
    "id": "same-query-repeated",
    "steps": [
      {
        "arguments": {
          "query": " same ordinary query "
        }
      },
      {
        "arguments": {
          "query": "same ordinary query"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "query-case-identity",
    "steps": [
      {
        "arguments": {
          "query": "Ordinary Case Query"
        }
      },
      {
        "arguments": {
          "query": "ordinary case query"
        }
      },
      {
        "arguments": {
          "query": " Ordinary Case Query "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "query-interior-space-identity",
    "steps": [
      {
        "arguments": {
          "query": "ordinary  spaced query"
        }
      },
      {
        "arguments": {
          "query": "ordinary spaced query"
        }
      },
      {
        "arguments": {
          "query": "ordinary  spaced query"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "count-identity",
    "steps": [
      {
        "arguments": {
          "query": "ordinary count identity",
          "count": 3
        }
      },
      {
        "arguments": {
          "query": "ordinary count identity",
          "count": 4
        }
      },
      {
        "arguments": {
          "query": "ordinary count identity",
          "count": " 3 "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "region-identity",
    "steps": [
      {
        "arguments": {
          "query": "ordinary region identity",
          "region": "us-en"
        }
      },
      {
        "arguments": {
          "query": "ordinary region identity",
          "region": "de-de"
        }
      },
      {
        "arguments": {
          "query": "ordinary region identity",
          "region": " us-en "
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "effective-region-identity",
    "steps": [
      {
        "arguments": {
          "query": "ordinary effective region"
        },
        "providerConfig": {
          "region": " us-en "
        }
      },
      {
        "arguments": {
          "query": "ordinary effective region",
          "region": "us-en"
        },
        "providerConfig": {
          "region": "de-de"
        }
      },
      {
        "arguments": {
          "query": "ordinary effective region",
          "region": " "
        },
        "providerConfig": {
          "region": "us-en"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>"
    ]
  },
  {
    "id": "cache-off",
    "steps": [
      {
        "arguments": {
          "query": "ordinary cache off"
        },
        "searchConfig": {
          "cacheTtlMinutes": 0
        }
      },
      {
        "arguments": {
          "query": "ordinary cache off"
        },
        "searchConfig": {
          "cacheTtlMinutes": 0
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>",
      "<div><a class=\"result__a\" href=\"https://changed.example/two\">Changed second response</a><a class=\"result__snippet\" href=\"https://changed.example/two\">Fresh ordinary content.</a></div>"
    ]
  },
  {
    "id": "cache-off-on",
    "steps": [
      {
        "arguments": {
          "query": "ordinary cache off on"
        },
        "searchConfig": {
          "cacheTtlMinutes": 0
        }
      },
      {
        "arguments": {
          "query": "ordinary cache off on"
        }
      },
      {
        "arguments": {
          "query": "ordinary cache off on"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>",
      "<div><a class=\"result__a\" href=\"https://changed.example/two\">Changed second response</a><a class=\"result__snippet\" href=\"https://changed.example/two\">Fresh ordinary content.</a></div>"
    ]
  },
  {
    "id": "cache-on-off-on",
    "steps": [
      {
        "arguments": {
          "query": "ordinary cache on off on"
        }
      },
      {
        "arguments": {
          "query": "ordinary cache on off on"
        },
        "searchConfig": {
          "cacheTtlMinutes": 0
        }
      },
      {
        "arguments": {
          "query": "ordinary cache on off on"
        }
      }
    ],
    "httpPayloads": [
      "<div><a class=\"result__a\" href=\"https://www.docs.example/one\"> First ordinary title </a><a class=\"result__snippet\" href=\"https://www.docs.example/one\"> First ordinary snippet. </a></div>\n<div><a href=\"https://news.example/two\" class=\"result__a\">Second ordinary title</a><a href=\"https://news.example/two\" class=\"result__snippet\">Second ordinary snippet.</a></div>",
      "<div><a class=\"result__a\" href=\"https://changed.example/two\">Changed second response</a><a class=\"result__snippet\" href=\"https://changed.example/two\">Fresh ordinary content.</a></div>"
    ]
  },
  {
    "id": "ordinary-protocol-relative",
    "steps": [
      {
        "arguments": {
          "query": "ordinary-protocol-relative"
        }
      },
      {
        "arguments": {
          "query": " ordinary-protocol-relative "
        }
      }
    ],
    "httpPayloads": [
      "<a class=\"result__a\" href=\"//www.relative.example/guide\">Relative source</a><a class=\"result__snippet\">Relative ordinary snippet.</a>"
    ]
  },
  {
    "id": "ordinary-redirect-links",
    "steps": [
      {
        "arguments": {
          "query": "ordinary-redirect-links"
        }
      }
    ],
    "httpPayloads": [
      "<a data-kind=\"ordinary\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.redirect.example%2Fguide%3Fa%3D1%26b%3D2&amp;rut=ordinary\" class=\"before result__a after\">Redirected title</a><a class=\"result__snippet\">Redirected snippet.</a><a class=\"result__a\" href=\"https://direct.example/guide?a=1&amp;b=2\">Direct entity URL</a><a class=\"result__snippet\">Direct snippet.</a>"
    ]
  },
  {
    "id": "ordinary-highlight-spacing",
    "steps": [
      {
        "arguments": {
          "query": "ordinary-highlight-spacing"
        }
      }
    ],
    "httpPayloads": [
      "<a data-order=\"first\" href=\"https://www.highlight.example/title\" class=\"one result__a two\"> Open<b class=\"match\">Claw</b> <span>source</span><em>guide</em> </a><a data-kind=\"snippet\" class=\"one result__snippet two\" href=\"https://www.highlight.example/title\"> Read <b>high</b>lights <span>with</span><em>spacing</em>. </a><a class=\"result__a other\" data-order=\"second\" href=\"https://second.example/guide\">Second <B>in</B>word</a><a href=\"https://second.example/guide\" class=\"other result__snippet\">Second <span>plain</span> snippet.</a>"
    ]
  },
  {
    "id": "ordinary-entities-once",
    "steps": [
      {
        "arguments": {
          "query": "ordinary-entities-once"
        }
      }
    ],
    "httpPayloads": [
      "<a class=\"result__a\" href=\"https://entities.example/guide?a=1&amp;b=2\">A &amp; B &lt;guide&gt; &quot;quote&quot; &apos;apostrophe&apos; &#39; &#x27; &#x2F; &nbsp; &ndash; &mdash; &hellip; &#169; &#x1F600; &amp;lt;</a><a class=\"result__snippet\">One&nbsp;&nbsp;two &AMP; &#65; &#x42; &amp;amp;</a>"
    ]
  },
  {
    "id": "ordinary-optional-snippets",
    "steps": [
      {
        "arguments": {
          "query": "ordinary-optional-snippets"
        }
      }
    ],
    "httpPayloads": [
      "<a class=\"result__a\" href=\"https://www.optional.example/one\">No snippet first</a><div>Ordinary layout separator</div><a href=\"https://www.optional.example/two\" class=\"result__a\">Snippet second</a><a class=\"result__snippet\">Second snippet belongs here.</a>"
    ]
  },
  {
    "id": "successful-empty",
    "steps": [
      {
        "arguments": {
          "query": "successful-empty"
        }
      }
    ],
    "httpPayloads": [
      "<html><body><p>No ordinary results.</p></body></html>"
    ]
  },
  {
    "id": "empty-cache-reuse",
    "steps": [
      {
        "arguments": {
          "query": "same empty query"
        }
      },
      {
        "arguments": {
          "query": "same empty query"
        }
      }
    ],
    "httpPayloads": [
      "<html><body><p>No ordinary results.</p></body></html>"
    ]
  }
];
}
function makeSetup(recipe, item = {}) {
  const searchConfig = { cacheTtlMinutes: 15, ...recipe.searchConfig, ...item.searchConfig };
  return { config: { tools: { web: { search: searchConfig } }, plugins: { entries: { duckduckgo: { config: { webSearch: {
    ...recipe.providerConfig, ...item.providerConfig,
  } } } } } }, searchConfig: plain(recipe.contextSearchConfig ?? searchConfig) };
}
function withoutStamps(value) {
  if (Array.isArray(value)) return value.map(withoutStamps);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .filter(([key]) => key !== 'externalContent').map(([key, item]) => [key, withoutStamps(item)]));
  return value;
}

export async function captureDuckDuckGoSearch(root = '/tmp/openclaw-488631c') {
  root = realpathSync(root);
  const before = checkout(root), artifact = entitiesArtifact(root);
  const sources = new Map(), aliases = new Map(), stubs = new Map(), generated = new Map(), dependencies = new Map(), entitiesDependencies = new Map();
  const merge = capture => {
    for (const [key, value] of capture.sources) sources.set(key, { ...value, executed: value.executed || sources.get(key)?.executed === true });
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
    for (const [key, value] of capture.generatedFacades) generated.set(key, value);
    for (const [key, value] of capture.dependencies) dependencies.set(key, value);
    for (const [key, value] of capture.entitiesDependencies) entitiesDependencies.set(key, value);
  };
  const normalizer = new DuckDuckGoCapture(root, undefined, artifact);
  const outputModule = normalizer.source(output); await normalizer.evaluate(outputModule);
  const normalize = outputModule.namespace.normalizeWebSearchOutput, unwrap = outputModule.namespace.unwrapWebSearchOutputText;
  const groups = [];
  for (const recipe of recipes()) {
    const capture = new DuckDuckGoCapture(root, recipe.httpPayloads, artifact), module = capture.source(entrypoint);
    await capture.evaluate(module);
    const provider = module.namespace.createDuckDuckGoWebSearchProvider();
    const setup = makeSetup(recipe, recipe.steps[0]), setupBefore = plain(setup), initialTool = provider.createTool(setup);
    const steps = [];
    for (const [n, item] of recipe.steps.entries()) {
      capture.nowMs = originMs + n * 20;
      const clock = new Date(capture.nowMs).toISOString(), stepSetup = makeSetup(recipe, item), originalSetup = plain(stepSetup);
      const args = plain(item.arguments), original = plain(args), requestCount = capture.requests.length;
      const result = plain(await provider.createTool(stepSetup).execute(args));
      assert.deepEqual(args, original); assert.deepEqual(stepSetup, originalSetup); assert.equal(result.provider, 'duckduckgo', recipe.id);
      const requests = capture.requests.slice(requestCount), cacheHit = result.cached === true;
      assert.equal(requests.length === 0, cacheHit, recipe.id);
      const generic = plain(normalize({ result, provider: 'duckduckgo', query: original.query }));
      assert.ok(['results', 'raw'].includes(generic.kind), recipe.id);
      const providerUnwrappedResult = mapProse(result, unwrap);
      const providerPortableResult = mapProse(result, (text, field) => field === 'siteName' ? text : unframeDuckDuckGoSearchText(text));
      delete providerPortableResult.externalContent;
      const genericUnwrappedResult = mapProse(generic, unwrap), genericPortableResult = withoutStamps(genericUnwrappedResult);
      steps.push({ arguments: original, argumentsAfter: plain(args), setup: originalSetup, setupAfter: plain(stepSetup),
        clock, clockAfter: new Date(capture.nowMs).toISOString(), requests, request: requests[0] ?? null,
        cacheHit, cumulativeRequests: capture.requests.length,
        providerResult: result, providerUnwrappedResult, providerPortableResult,
        genericResult: generic, genericUnwrappedResult, genericPortableResult,
        publicResult: generic, publicUnwrappedResult: genericUnwrappedResult, publicPortableResult: genericPortableResult });
    }
    assert.deepEqual(setup, setupBefore);
    groups.push({ id: recipe.id, setup: setupBefore, setupAfter: plain(setup),
      providerMetadata: plain(Object.fromEntries(['id', 'label', 'hint', 'onboardingScopes', 'requiresCredential',
        'credentialLabel', 'envVars', 'placeholder', 'signupUrl', 'docsUrl', 'autoDetectOrder', 'credentialPath',
        'credentialNote', 'inactiveSecretPaths'].map(key => [key, provider[key]]))),
      descriptor: { description: initialTool.description, parameters: plain(initialTool.parameters) },
      httpPayloads: plain(recipe.httpPayloads), steps, audit: plain(capture.audit) });
    merge(capture);
  }
  merge(normalizer);
  const after = checkout(root); assert.deepEqual(after, before);
  const licenseBytes = readFileSync(join(root, 'LICENSE'));
  assert.deepEqual(licenseBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:LICENSE`]));
  const packagePath = 'extensions/duckduckgo/package.json', packageBytes = readFileSync(join(root, packagePath));
  assert.deepEqual(packageBytes, execFileSync('git', ['-C', root, 'show', `${BRAVE_REFERENCE_PIN}:${packagePath}`]));
  const pluginVersion = JSON.parse(packageBytes).version;
  assert.equal(dependencies.size, 372, 'actual full TypeBox module graph plus package metadata');
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-duckduckgo-search.mjs', sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'pin-verified whole-module loader, synthetic clock/randomBytes; DuckDuckGo owns audited success/platform/version facades and actual entities package loader' }],
    license: { path: 'LICENSE', gitBlob: blob(licenseBytes), sha256: digest(licenseBytes), text: licenseBytes.toString() },
    pluginFixture: { path: packagePath, gitBlob: blob(packageBytes), sha256: digest(packageBytes), version: pluginVersion,
      userAgent: `openclaw-duckduckgo/${pluginVersion} (+https://docs.openclaw.ai)` },
    source: entrypoint, export: 'createDuckDuckGoWebSearchProvider',
    invocations: ['createDuckDuckGoWebSearchProvider().createTool(setup).execute(arguments)',
      'normalizeWebSearchOutput({result,provider:"duckduckgo",query:authoredArguments.query})',
      'unwrapWebSearchOutputText(providerAndGenericProse)'],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)', checkout: { before, after },
    boundaries: { fullSourceModules: true, bodyProjections: false, publicEntrypointInvoked: true, factoryInvoked: true,
      publicCallbackInvoked: true, actualLazyClient: true, actualProviderRequestBuilder: true,
      actualCountReaders: true, actualConfigReaders: true, actualSourceCache: true, actualHtmlEntityModule: true,
      actualEntities: true, genericNormalizerInvoked: true, actualUnwrapInvoked: true, actualTypeBox: true,
      actualPluginVersionDiscovery: false, actualBoundedSuccessReader: false, actualEndpointClassifiers: false,
      actualEndpointPolicy: false, actualDeadline: false, productionNetworkInvoked: false,
      pluginRegistrationInvoked: false, hostInstalled: false, fixtureEnvironment: {},
      syntheticClock: 'Date construction/Date.now; each successful GET advances7ms; no actual timers',
      portableNormalization: 'provider portable removes exact title/snippet frames and stamp, retaining plain siteName; generic portable uses actual unwrap then recursively removes stamps including raw.data; public aliases generic',
      limits: [
        'All58558 tracked pinned blobs verified before/after; executed means unchanged whole-module evaluation, not every branch/export',
        'Actual public entrypoint/factory/contract/config readers/lazy client/query/count/time/cache/request/HTML parser/siteName/output execute',
        'Actual pinned html-entity-runtime/shared/html-entities and entities8.1.0 ESM graph execute; package files match cached tarball with pinned lock SHA512 integrity',
        'Only successful short HTML endpoint/text and package-version fixtures; actual network/platform discovery/endpoint services/timers remain unexecuted',
        'Default count5, explicit3/numeric4; configured tools maxResults and timeoutSeconds and ctx.searchConfig are ignored by this source factory; effective timeout20',
        'Count affects parser/cache identity and is absent from GET; every HTML fixture has at most two short ordinary rows, with no quota slicing',
        'Provider cache identity preserves trimmed query case/interior spaces plus count and effective region; config region trims and blank argument falls back to config',
        'TTL0 disables source cache reads/writes without deleting old entries; distinct second HTML demonstrates off/on storage and on/off/on old-payload preservation',
        'Direct protocol-relative URL remains protocol-relative with omitted siteName; actual generic source therefore retains complete original provider data in its raw branch',
        'Ordinary direct/redirect links, attribute/class placement, b highlights within words, tag spacing, optional snippets and www siteNames are observed unchanged',
        'Entity decoding is once after HTML stripping; ordinary named/numeric entities retain source-specific spacing and punctuation conversions',
        'Generic results preserve authored query, canonicalize ordinary absolute URLs and reframe siteName; provider/generic original frames and actual unwrap maps remain complete',
        'Excluded security/permission/auth/TLS/negative/error/failure/cancel/crash/mixed/budget/truncation/eviction/threshold/race/real-provider/remote-MCP branches unexecuted',
        'No Synapsis host/runtime/Worker/Concord or deployment acceptance; full P0-P15 incomplete',
      ] },
    counts: { executedWholeModules: [...sources.values()].filter(row => row.executed).length,
      provenanceOnlyModules: [...sources.values()].filter(row => !row.executed).length, groups: groups.length,
      callbacks: groups.reduce((n, row) => n + row.steps.length, 0),
      httpBearingCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.requests.length > 0).length, 0),
      httpRequests: groups.reduce((n, row) => n + row.steps.reduce((m, item) => m + item.requests.length, 0), 0),
      cacheHitCallbacks: groups.reduce((n, row) => n + row.steps.filter(item => item.cacheHit).length, 0) },
    sources: sorted([...sources.values()].map(source => ({ ...source, gitBlob: blob(readFileSync(join(root, source.path))) }))),
    aliases: sorted(aliases.values()), facades: sorted(generated.values()), stubs: sorted(stubs.values()),
    typebox: { version: normalizer.typeboxVersion, files: sorted(dependencies.values()) },
    entities: { version: '8.1.0', files: sorted(entitiesDependencies.values()), artifact: artifact.artifact }, groups,
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', out] = process.argv.slice(2);
  const captured = await captureDuckDuckGoSearch(root), json = JSON.stringify(captured, null, 2) + '\n';
  if (out) writeFileSync(out, json); else process.stdout.write(json);
}
