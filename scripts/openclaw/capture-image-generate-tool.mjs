// Complete pinned image_generate factory/actions under named synthetic positive data snapshots.
// This exporter never invokes generation, provider I/O, authentication, or registry lifecycle.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, posix, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

export const IMAGE_GENERATE_TOOL_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const runtimeRoot = '/tmp/synapsis-openclaw-capture-runtime';
const fixedNode = runtimeRoot + '/node_modules/node/bin/node';
const entry = 'src/agents/tools/image-generate-tool.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const inside = (root, file) => file === root || file.startsWith(root + sep);

// Explicit whole-module closure. No source regions or function bodies are extracted.
const wholeSources = new Set([
  entry,
  ...[
    'agents/tools/image-generate-tool.actions', 'agents/tools/media-generate-tool-actions-shared',
    'agents/tools/media-tool-shared', 'agents/tools/common', 'agents/tools/tool-results',
    'agents/media-generation-task-status', 'agents/media-generation-task-status-shared',
    'agents/session-async-task-status', 'agents/sanitize-for-prompt',
    'image-generation/resolution', 'media-generation/model-ref', 'param-key',
    'agents/schema/string-enum', 'shared/enum-option', 'shared/human-list', 'agents/tool-input-error',
  ].map(path => 'src/' + path + '.ts'),
  ...['catalog', 'model-ref', 'capability-model-ref'].map(path => 'packages/media-generation-core/src/' + path + '.ts'),
  ...['model-catalog-refs', 'provider-id'].map(path => 'packages/model-catalog-core/src/' + path + '.ts'),
  ...['index', 'balanced-json', 'boolean-coercion', 'cjk-chars', 'code-points', 'error-coercion',
    'expect', 'format', 'json-coercion', 'number-coercion', 'record-coerce', 'response-bytes',
    'stable-stringify', 'string-coerce', 'string-normalization', 'text-decoding', 'utf16-slice',
  ].map(path => 'packages/normalization-core/src/' + path + '.ts'),
]);
const deferredSources = new Set([
  'media/configured-max-bytes', 'media/media-probe', 'media/store', 'media/store.shared',
  'plugin-sdk/boolean-param', 'plugins/config-state', 'media/channel-inbound-roots',
  'media/local-media-access', 'media/media-reference', 'plugins/sdk-deprecation',
  'utils', 'utils/fetch-timeout', 'agents/sandbox-media-paths', 'agents/workspace-dir',
  'infra/fs-safe', 'routing/session-key', 'image-generation/runtime', 'media/media-services',
  'agents/tools/generated-media-batch-persistence', 'agents/tools/media-generate-result-shared',
  'agents/tools/media-generation-tool-providers',
].map(path => 'src/' + path + '.ts'));
const externalDeferred = {
  '@openclaw/fs-safe/advanced': { source: 'package.json', exports: ['safeFileURLToPath'] },
  '@openclaw/media-core/inbound-path-policy': {
    source: 'packages/media-core/src/inbound-path-policy.ts', exports: ['normalizeInboundPathRoots'],
  },
  '@openclaw/media-core/mime': { source: 'packages/media-core/src/mime.ts', exports: ['detectMime', 'extensionForMime'] },
  '@openclaw/media-core/file-name': { source: 'packages/media-core/src/file-name.ts', exports: ['extnameFromAnyPath'] },
};

// These are successful supplied data boundaries, not implementations of their source owners.
// Each generated binding and original source hash is included in the report.
const facadeCode = {
  'src/logging/subsystem.ts': {
    createSubsystemLogger: `export function createSubsystemLogger(name){
      __calls.push({callback:'createSubsystemLogger',name});return {};
    }`,
  },
  'src/agents/tools/media-generate-background.ts': {
    resolveMediaGenerateToolContext: `export function resolveMediaGenerateToolContext(key,options,log,preparedAvailability){
      __calls.push({callback:'resolveMediaGenerateToolContext',key,options,preparedAvailability});
      return {cfg:__input.config,sandboxConfig:undefined,taskOptions:{}};
    }`,
  },
  'src/agents/tools/model-config.helpers.ts': {
    prepareToolAuthProfileStore: `export async function prepareToolAuthProfileStore(options){
      __calls.push({callback:'prepareToolAuthProfileStore',options,source:'inert supplied success'});return {};
    }`,
  },
  'src/agents/tools/manifest-capability-availability.ts': {},
  'src/plugins/manifest-contract-eligibility.ts': {},
  'src/secrets/provider-env-vars.ts': {
    getProviderEnvVarsCore: `export function getProviderEnvVarsCore(providerId){
      __calls.push({callback:'getProviderEnvVarsCore',providerId});return __input.authEnvVars;
    }`,
  },
  'src/media-generation/registry.ts': {
    withImageGenerationProviders: `export function withImageGenerationProviders(config,run){
      __calls.push({callback:'withImageGenerationProviders',config});return run(__providers);
    }`,
  },
  'src/agents/media-generation-activity.ts': {
    listMediaGenerationOperations: `export function listMediaGenerationOperations(sessionKey,agentId){
      __calls.push({callback:'listMediaGenerationOperations',sessionKey,agentId});return __input.operations;
    }`,
  },
};
const hostCode = `
globalThis.__deferredCalls=[];
globalThis.__calls=[];
globalThis.__defer=name=>{__deferredCalls.push(name);throw Error('uninvoked capture binding: '+name);};
globalThis.__plain=value=>JSON.parse(JSON.stringify(value));
`;
const vectorSetupCode = `
globalThis.__input=JSON.parse(__serializedInput);
globalThis.__providers=__input.providers.map(provider=>({...provider,
  isConfiguredAsync:async context=>{
    __calls.push({callback:'isConfiguredAsync',provider:provider.id,context,value:__input.configured});
    return __input.configured;
  }
}));
`;

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}
function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), IMAGE_GENERATE_TOOL_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', IMAGE_GENERATE_TOOL_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, gitBlob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const stat = lstatSync(file);
    const symlink = stat.isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    if (!symlink) {
      assert.ok(stat.isFile(), path);
      assert.equal(Boolean(stat.mode & 0o111), mode === '100755', `executable mode: ${path}`);
    }
    assert.ok(inside(root, realpathSync(file)));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), gitBlob, path);
    return { path, mode, gitBlob, sha256: hash(bytes), symlink,
      ...(symlink ? { symlinkTarget: readlinkSync(file) } : {}) };
  });
  assert.equal(files.length, 58558, 'complete pinned tracked tree');
  return { tracked: new Map(files.map(row => [row.path, row])),
    receipt: { verified: true, commit: IMAGE_GENERATE_TOOL_PIN,
      tree: git(root, ['rev-parse', `${IMAGE_GENERATE_TOOL_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) } };
}

// Import declarations come from unchanged transformed modules. This only names
// throwing bindings for explicitly deferred modules; it never selects source bodies.
function requestedExports(code, specifier) {
  const found = new Set();
  const pattern = /(?:import|export)\s*\{([^}]+)\}\s*from\s*["']([^"']+)["']/g;
  for (const match of code.matchAll(pattern)) if (match[2] === specifier) {
    for (const name of match[1].split(',')) found.add(name.trim().split(/\s+as\s+/)[0]);
  }
  assert.ok(found.size > 0, `named deferred import required: ${specifier}`);
  return [...found].sort();
}

class ImageGenerateToolHarness {
  constructor(root, tracked) {
    this.root = root;
    this.tracked = tracked;
    this.context = vm.createContext({ Buffer, TextEncoder, TextDecoder, URL, AbortController, structuredClone },
      { codeGeneration: { strings: false, wasm: false } });
    new vm.Script(hostCode).runInContext(this.context, { timeout: 1000 });
    this.modules = new Map();
    this.records = new Map();
    this.bindings = new Map();
    this.packages = new Map();
    this.code = new Map();
  }
  sourceRecord(path, executed = false) {
    const bytes = readFileSync(join(this.root, path));
    const pinned = this.tracked.get(path);
    assert.ok(pinned, path);
    assert.equal(hash(bytes), pinned.sha256, path);
    if (!this.records.has(path)) this.records.set(path, { ...pinned, executed: false, originalSourceExecuted: false });
    if (executed) {
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      this.records.set(path, { ...pinned, executed: true, originalSourceExecuted: true, wholeModule: true, transformation,
        executableSha256: hash(executable) });
      return executable;
    }
    return bytes.toString();
  }
  synthetic(key, generatedCode, evidence) {
    if (!this.modules.has(key)) {
      this.bindings.set(key, { ...evidence, generatedCode, generatedSha256: hash(generatedCode) });
      this.modules.set(key, new vm.SourceTextModule(generatedCode, { context: this.context, identifier: key }));
    }
    return this.modules.get(key);
  }
  source(path) {
    if (this.modules.has(path)) return this.modules.get(path);
    assert.ok(wholeSources.has(path), `undeclared whole module: ${path}`);
    assert.ok(!deferredSources.has(path), `deferred module execution: ${path}`);
    const executable = this.sourceRecord(path, true);
    this.code.set(path, executable);
    const module = new vm.SourceTextModule(executable, { context: this.context, identifier: path,
      importModuleDynamically: specifier => {
        this.context.__deferredCalls.push({ importer: path, specifier, kind: 'dynamic-import' });
        throw Error('dynamic import outside ordinary capture');
      } });
    this.modules.set(path, module);
    return module;
  }
  packageFile(name, file) {
    const pkg = this.packages.get(name);
    const actual = realpathSync(file);
    assert.ok(inside(pkg.root, actual));
    const path = posix.relative(pkg.root, actual);
    const bytes = readFileSync(actual);
    pkg.files.set(path, { path, sha256: hash(bytes) });
    const key = `package:${name}/${path}`;
    if (!this.modules.has(key)) this.modules.set(key,
      new vm.SourceTextModule(bytes.toString(), { context: this.context, identifier: key }));
    return this.modules.get(key);
  }
  dependency(name, specifier) {
    const root = realpathSync(runtimeRoot + '/node_modules/' + name);
    const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
    const subpath = specifier === name ? '.' : '.' + specifier.slice(name.length);
    const target = manifest.exports[subpath];
    const importTarget = typeof target === 'string' ? target : target.import ?? target.default;
    assert.equal(typeof importTarget, 'string', `${specifier} ESM package export`);
    const file = realpathSync(join(root, importTarget));
    if (!this.packages.has(name)) {
      assert.equal(name, 'typebox');
      const expectedVersion = '1.3.37';
      assert.equal(manifest.name, name);
      assert.equal(manifest.version, expectedVersion);
      const referencePackage = JSON.parse(this.sourceRecord('package.json'));
      assert.equal(referencePackage.dependencies[name], expectedVersion);
      const lock = this.sourceRecord('pnpm-lock.yaml');
      const match = lock.match(new RegExp(`^  ${name}@${expectedVersion.replaceAll('.', '\\.')}:[\\s\\S]*?resolution: \\{integrity: ([^}]+)\\}`, 'm'));
      assert.ok(match, `pinned ${name} integrity`);
      this.packages.set(name, { name, version: expectedVersion, root, lockIntegrity: match[1],
        referenceManifest: 'package.json', referenceLock: 'pnpm-lock.yaml',
        entryResolution: 'actual package exports import condition',
        files: new Map(['package.json', 'license'].map(path =>
          [path, { path, sha256: hash(readFileSync(join(root, path))) }])) });
    }
    return this.packageFile(name, file);
  }
  wholeImport(importer, specifier, path) {
    const module = this.source(path);
    this.bindings.set(`import:${importer}:${specifier}`, {
      importer, specifier, source: path, sourceSha256: this.tracked.get(path).sha256,
      kind: 'actual-whole-source-module', originalSourceExecuted: true,
    });
    return module;
  }
  packageImport(importer, specifier, module) {
    const path = module.identifier.slice('package:typebox/'.length);
    this.bindings.set(`import:${importer}:${specifier}`, {
      importer, specifier, source: module.identifier,
      sourceSha256: this.packages.get('typebox').files.get(path).sha256,
      kind: 'actual-whole-package-module', originalSourceExecuted: true,
    });
    return module;
  }
  async import(specifier, owner) {
    const importer = owner.identifier;
    if (importer.startsWith('package:')) {
      const name = importer.slice('package:'.length).split('/')[0];
      const path = importer.slice(`package:${name}/`.length);
      assert.ok(specifier.startsWith('.'), `package relative import required: ${specifier}`);
      return this.packageImport(importer, specifier,
        this.packageFile(name, resolve(this.packages.get(name).root, dirname(path), specifier)));
    }
    if (specifier.startsWith('node:')) {
      assert.equal(specifier, 'node:path', `undeclared platform import: ${specifier}`);
      const key = 'platform:' + specifier;
      if (!this.modules.has(key)) {
        const namespace = await import(specifier);
        const names = Object.keys(namespace);
        this.bindings.set(key, { kind: 'actual-platform-builtin', importer, specifier, exports: names });
        this.modules.set(key, new vm.SyntheticModule(names, function () {
          for (const name of names) this.setExport(name, namespace[name]);
        }, { context: this.context, identifier: key }));
      }
      return this.modules.get(key);
    }
    if (specifier === 'typebox' || specifier.startsWith('typebox/')) {
      return this.packageImport(importer, specifier, this.dependency('typebox', specifier));
    }
    if (Object.hasOwn(externalDeferred, specifier)) {
      const { source, exports: allowed } = externalDeferred[specifier];
      const names = requestedExports(this.code.get(importer), specifier);
      assert.ok(names.every(name => allowed.includes(name)), `undeclared external export: ${specifier}`);
      this.sourceRecord(source);
      return this.synthetic('capture:external:' + importer + ':' + specifier,
        names.map(name => `export function ${name}(){return __defer(${JSON.stringify(specifier + ':' + name)});}`).join('\n'),
        { kind: 'uninvoked-external-package-binding', importer, specifier, exports: names,
          source, referenceManifest: source === 'package.json' ? 'package.json' : null,
          sourceSha256: this.tracked.get(source).sha256,
          originalSourceExecuted: false });
    }
    const packageAliases = {
      '@openclaw/normalization-core': 'packages/normalization-core/src/',
      '@openclaw/model-catalog-core': 'packages/model-catalog-core/src/',
    };
    for (const [name, prefix] of Object.entries(packageAliases)) {
      if (specifier === name || specifier.startsWith(name + '/')) {
        return this.wholeImport(importer, specifier, prefix + (specifier.slice(name.length + 1) || 'index') + '.ts');
      }
    }
    assert.ok(specifier.startsWith('.'), `undeclared import: ${importer} -> ${specifier}`);
    const target = posix.normalize(posix.join(posix.dirname(importer), specifier)).replace(/\.js$/, '.ts');
    if (Object.hasOwn(facadeCode, target)) {
      this.sourceRecord(target);
      const supplied = facadeCode[target];
      // Every inactive imported export is a throwing binding, never an inferred implementation.
      const names = requestedExports(this.code.get(importer), specifier);
      const generatedCode = names.map(name => Object.hasOwn(supplied, name)
        ? supplied[name]
        : `export function ${name}(){return __defer(${JSON.stringify(target + ':' + name)});}`).join('\n');
      return this.synthetic('capture:facade:' + importer + ':' + target, generatedCode, {
        importer, specifier, source: target, sourceSha256: this.tracked.get(target).sha256,
        kind: 'explicit-inert-supplied-fixture-facade', exports: names,
        originalSourceExecuted: false });
    }
    if (deferredSources.has(target)) return this.deferred(importer, specifier, target);
    return this.wholeImport(importer, specifier, target);
  }
  deferred(importer, specifier, target, names, classBinding = false) {
    this.sourceRecord(target);
    names ??= requestedExports(this.code.get(importer), specifier);
    const code = names.map(name => classBinding
      ? `export class ${name} extends Error{constructor(){super();__defer(${JSON.stringify(target + ':' + name)});}}`
      : `export function ${name}(){return __defer(${JSON.stringify(target + ':' + name)});}`).join('\n');
    return this.synthetic(`capture:deferred:${importer}:${specifier}`, code, {
      importer, specifier, source: target, sourceSha256: this.tracked.get(target).sha256,
      exports: names, kind: 'uninvoked-throwing-binding', originalSourceExecuted: false });
  }
  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
  async load(path) {
    const module = this.source(path);
    if (module.status === 'unlinked') await module.link((specifier, owner) => this.import(specifier, owner));
    if (module.status === 'linked') await module.evaluate({ timeout: 1000 });
    assert.equal(module.status, 'evaluated');
    return module.namespace;
  }
}

// Inputs frozen independently before capture; these contain no expected outputs.
const cases = {
  "factory": [
    {
      "id": "default-positive-context",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": []
      }
    },
    {
      "id": "explicit-session-agent-context",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": [],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        }
      }
    }
  ],
  "action": [
    {
      "id": "list-edit-and-generate",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [
          {
            "id": "fixture-image-edit",
            "label": "Fixture Image Edit",
            "defaultModel": "image-main",
            "models": [
              "image-main",
              "image-fast"
            ],
            "capabilities": {
              "generate": {
                "maxCount": 4,
                "supportsSize": true,
                "supportsAspectRatio": true,
                "supportsResolution": true
              },
              "edit": {
                "enabled": true,
                "maxCount": 2,
                "maxInputImages": 5,
                "maxInputImagesByModel": {
                  "image-main": 8,
                  "image-fast": 3
                },
                "maxInputImagesByModelPrefix": {
                  "image-": 6
                },
                "supportsSize": true,
                "supportsAspectRatio": true
              }
            }
          },
          {
            "id": "fixture-image-generate",
            "label": "Fixture Image Generate",
            "defaultModel": "image-basic",
            "models": [
              "image-basic"
            ],
            "capabilities": {
              "generate": {
                "maxCount": 1,
                "supportsSize": true
              },
              "edit": {
                "enabled": false
              }
            }
          }
        ],
        "operations": [],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "list"
        }
      }
    },
    {
      "id": "list-geometry-output",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [
          {
            "id": "fixture-image-geometry",
            "label": "Fixture Image Geometry",
            "defaultModel": "image-hd",
            "models": [
              "image-hd",
              "image-wide"
            ],
            "capabilities": {
              "generate": {
                "maxCount": 3,
                "supportsSize": true,
                "supportsAspectRatio": true,
                "supportsResolution": true
              },
              "edit": {
                "enabled": true,
                "maxInputImages": 1,
                "supportsResolution": true
              },
              "geometry": {
                "resolutions": [
                  "1K",
                  "2K",
                  "4K"
                ],
                "resolutionsByModel": {
                  "image-hd": [
                    "2K",
                    "4K"
                  ]
                },
                "sizes": [
                  "1024x1024",
                  "1536x1024"
                ],
                "sizesByModel": {
                  "image-wide": [
                    "1536x1024"
                  ]
                },
                "aspectRatios": [
                  "1:1",
                  "3:2"
                ],
                "aspectRatiosByModel": {
                  "image-wide": [
                    "3:2"
                  ]
                }
              },
              "output": {
                "qualities": [
                  "medium",
                  "high"
                ],
                "qualitiesByModel": {
                  "image-hd": [
                    "high"
                  ]
                },
                "formats": [
                  "png",
                  "jpeg",
                  "webp"
                ],
                "formatsByModel": {
                  "image-wide": [
                    "jpeg"
                  ]
                },
                "backgrounds": [
                  "opaque",
                  "transparent"
                ],
                "backgroundsByModel": {
                  "image-hd": [
                    "opaque"
                  ]
                }
              }
            }
          }
        ],
        "operations": [],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "list"
        }
      }
    },
    {
      "id": "status-idle",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": [],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "status"
        }
      }
    },
    {
      "id": "status-queued",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": [
          {
            "taskId": "image-queued",
            "runId": "run-queued",
            "taskKind": "image_generation",
            "status": "queued",
            "sourceId": "image_generate:fixture-image-edit",
            "requesterSessionKey": "agent:fixture-agent:main",
            "requesterAgentId": "fixture-agent",
            "progressSummary": "Waiting for fixture slot"
          }
        ],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "status"
        }
      }
    },
    {
      "id": "status-running",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": [
          {
            "taskId": "image-running",
            "runId": "run-running",
            "taskKind": "image_generation",
            "status": "running",
            "sourceId": "image_generate:fixture-image-edit",
            "requesterSessionKey": "agent:fixture-agent:main",
            "requesterAgentId": "fixture-agent",
            "progressSummary": "Rendering image 2 of 3"
          }
        ],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "status"
        }
      }
    },
    {
      "id": "status-plural",
      "input": {
        "config": {
          "agents": {
            "defaults": {
              "mediaModels": {
                "image": {
                  "primary": "fixture-image-edit/image-main"
                }
              }
            }
          }
        },
        "preparedAvailability": true,
        "configured": true,
        "authEnvVars": [],
        "providers": [],
        "operations": [
          {
            "taskId": "image-queued",
            "runId": "run-queued",
            "taskKind": "image_generation",
            "status": "queued",
            "sourceId": "image_generate:fixture-image-edit",
            "requesterSessionKey": "agent:fixture-agent:main",
            "requesterAgentId": "fixture-agent",
            "progressSummary": "Waiting for fixture slot"
          },
          {
            "taskId": "image-running",
            "runId": "run-running",
            "taskKind": "image_generation",
            "status": "running",
            "sourceId": "image_generate:fixture-image-edit",
            "requesterSessionKey": "agent:fixture-agent:main",
            "requesterAgentId": "fixture-agent",
            "progressSummary": "Rendering image 2 of 3"
          }
        ],
        "options": {
          "workspaceDir": "/fixture/workspace",
          "agentDir": "/fixture/agent",
          "agentSessionKey": "agent:fixture-agent:main",
          "requesterAgentId": "fixture-agent"
        },
        "args": {
          "action": "status"
        }
      }
    }
  ]
};

// Output data is JSON-native. Reject unexpected lossy primitive conversions rather
// than conflating undefined/null, non-finite numbers, -0, strings, booleans or zero.
function jsonBytes(value, label) {
  const visit = (item, path) => {
    if (item === null || typeof item === 'string' || typeof item === 'boolean') return;
    if (typeof item === 'number') {
      assert.ok(Number.isFinite(item) && !Object.is(item, -0), `non-JSON number: ${path}`);
      return;
    }
    assert.equal(typeof item, 'object', `non-JSON primitive: ${path}`);
    if (Array.isArray(item)) {
      for (let index = 0; index < item.length; index++) {
        assert.ok(Object.hasOwn(item, index), `sparse array: ${path}`);
        visit(item[index], `${path}[${index}]`);
      }
    } else {
      for (const key of Object.keys(item)) visit(item[key], `${path}.${key}`);
    }
  };
  visit(value, label);
  return JSON.stringify(value);
}

function mergeRecord(map, key, row) {
  const previous = map.get(key);
  if (!previous) map.set(key, row);
  else assert.deepEqual(previous, row, `fresh-VM provenance drift: ${key}`);
}

export async function captureImageGenerateTool(sourceRoot = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(sourceRoot);
  const before = checkout(root);
  const allSources = new Map();
  const allBindings = new Map();
  const allPackages = new Map();
  const factories = [];
  const actions = [];
  for (const [kind, rows] of Object.entries(cases)) {
    for (const row of rows) {
      // Every vector gets original whole modules, actual TypeBox, and fresh supplied state.
      const harness = new ImageGenerateToolHarness(root, before.tracked);
      harness.context.__serializedInput = jsonBytes(row.input, row.id);
      harness.run(vectorSetupCode);
      harness.context.__factory = await harness.load(entry);
      harness.run(`globalThis.__tool=__factory.createImageGenerateTool(__input.options,__input.preparedAvailability);`);
      assert.ok(harness.context.__tool, 'supplied positive factory context');
      if (kind === 'factory') {
        // Preserve every nonfunction metadata field, rather than projecting selected keys.
        // TypeBox symbol annotations have no JSON representation; original JSON schema is retained.
        const definition = harness.run(`Object.fromEntries(Object.entries(__tool).filter(([,value])=>typeof value!=='function'))`);
        const definitionJson = jsonBytes(definition, row.id + '.definition');
        factories.push({ ...row, definition: JSON.parse(definitionJson),
          calls: plain(harness.context.__calls), deferredCalls: plain(harness.context.__deferredCalls) });
      } else {
        assert.ok(['list','status'].includes(row.input.args.action), 'ordinary metadata action only');
        const result = await harness.run('__tool.execute("fixture-image-tool-call",__input.args)');
        const resultJson = jsonBytes(result, row.id + '.result');
        actions.push({ ...row, result: JSON.parse(resultJson),
          calls: plain(harness.context.__calls), deferredCalls: plain(harness.context.__deferredCalls) });
      }
      assert.deepEqual(plain(harness.context.__deferredCalls), [], row.id);
      for (const source of harness.records.values()) {
        const prior = allSources.get(source.path);
        if (!prior || (!prior.executed && source.executed)) allSources.set(source.path, source);
        else if (prior.executed === source.executed) assert.deepEqual(prior, source);
      }
      for (const [key, binding] of harness.bindings) mergeRecord(allBindings, key, { key, ...binding });
      for (const pkg of harness.packages.values()) {
        let aggregate = allPackages.get(pkg.name);
        if (!aggregate) { aggregate = { ...pkg, files: new Map() }; allPackages.set(pkg.name, aggregate); }
        for (const [key, file] of pkg.files) mergeRecord(aggregate.files, key, file);
      }
    }
  }
  const after = checkout(root);
  assert.deepEqual(after.receipt, before.receipt);
  const sorted = rows => rows.sort((a,b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return {
    schemaVersion: 1,
    referenceCommit: IMAGE_GENERATE_TOOL_PIN,
    sourceTree: { before: before.receipt, after: after.receipt },
    sourceRecords: sorted([...allSources.values()]),
    importBindings: [...allBindings.values()].sort((a,b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0),
    externalDependencies: [...allPackages.values()].map(pkg => ({ ...pkg, files: sorted([...pkg.files.values()]) }))
      .sort((a,b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
    runtime: {
      node: { executable: fixedNode, version: process.versions.node,
        sha256: hash(readFileSync(fixedNode)), platform: process.platform },
      transformation,
      entry: { path: entry, export: 'createImageGenerateTool', sha256: before.tracked.get(entry).sha256 },
      host: { generatedCode: hostCode, sha256: hash(hostCode) },
      vectorSetup: { generatedCode: vectorSetupCode, sha256: hash(vectorSetupCode) },
      importPolicy: {
        wholeSources: [...wholeSources], deferredSources: [...deferredSources],
        suppliedFacadeSources: Object.keys(facadeCode), externalDeferred,
        platformImports: ['node:path'], packages: ['typebox'], dynamicImports: 'fail closed',
      },
    },
    exporter: {
      path: 'scripts/openclaw/capture-image-generate-tool.mjs', sha256: hash(readFileSync(fileURLToPath(import.meta.url))),
      adaptedHarness: { path: 'scripts/openclaw/capture-video-tool.mjs',
        sha256: hash(readFileSync(new URL('./capture-video-tool.mjs', import.meta.url))),
        relationship: 'standalone whole-module VM/package/checkout harness adapted; no helper import execution' },
    },
    limits: {
      factorySourceUnchanged: true, wholeOriginalModules: true, freshVmPerCase: true,
      factoryExecuted: true, listExecuted: true, statusExecuted: true,
      catalogSourceExecuted: true, statusOwnerSourceExecuted: true,
      schema: 'actual TypeBox 1.3.37; complete original factory JSON schema; symbol annotations omitted by JSON encoding',
      metadata: 'all own enumerable nonfunction fields retained',
      context: 'named synthetic positive tool context/config snapshots; no production availability resolution',
      providerRegistry: 'named synthetic provider metadata; configured state supplied true by inert callbacks',
      taskSnapshot: 'named synthetic same-session/same-agent queued/running operation arrays; actual original status filtering/builders',
      authentication: 'inert supplied store and environment metadata; no credential lookup or authentication execution',
      generateExecuted: false, duplicateGuardExecuted: false, providerGenerationExecuted: false,
      providerIOExecuted: false, taskRegistryExecuted: false, lifecycleExecuted: false,
      jobExecuted: false, completionExecuted: false, pluginLoaderExecuted: false,
      authExecuted: false, permissionExecuted: false, policyAcceptanceExecuted: false,
      availabilityResolutionExecuted: false, modelConfigNormalizationExecuted: false,
      networkExecuted: false, storageExecuted: false, canonicalFactoryComplete: false,
      runtimeAssemblyComplete: false, fullToolParity: false,
      unexecutedBranches: ['generate', 'duplicate guard', 'provider requests', 'jobs', 'completion delivery',
        'real plugin loading', 'production availability/readiness', 'authentication', 'permissions',
        'credential/environment lookup', 'network', 'storage', 'lifecycle/cancellation/failure/recovery'],
    },
    factories,
    actions,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [sourceRoot, flag, output] = process.argv.slice(2);
  assert.ok(sourceRoot && flag === '--out' && output && process.argv.length === 5,
    'usage: capture-image-generate-tool.mjs PINNED_SOURCE --out OUTPUT_JSON');
  const report = await captureImageGenerateTool(sourceRoot);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output: resolve(output), factories: report.factories.length,
    actions: report.actions.length, wholeSourceModules: report.sourceRecords.filter(row => row.executed).length }) + '\n');
}
