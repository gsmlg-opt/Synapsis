// Whole pinned MCP Events factory/callback and Gateway projection. Host services are fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import vm from 'node:vm';
import { FactoryHarness } from './capture-recipes.mjs';

export const MCP_EVENTS_PIN = '488631c18fae7cc541ba8fc8beff6cbb0438787b';
const fixedRoot = '/tmp/openclaw-488631c';
const fixedNode = '/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node';
const entry = 'extensions/mcp-events/index.ts';
const gateway = 'src/gateway/server-methods/mcp-events.ts';
const record = 'packages/normalization-core/src/record-coerce.ts';
const pluginEntry = 'src/plugin-sdk/plugin-entry.ts';
const lazy = 'src/plugin-sdk/lazy-value.ts';
const capabilityTypes = 'src/plugins/capability-provider.types.ts';
const protocol = 'extensions/mcp-events/src/protocol.ts';
const request = 'src/agents/mcp-event-request.ts';
const transformation = 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)';
const wholeSources = [entry, gateway, record, pluginEntry, lazy, capabilityTypes];
const provenancePaths = [
  'src/plugin-sdk/string-coerce-runtime.ts', 'src/plugins/config-schema.ts',
  'extensions/mcp-events/src/config.ts', protocol, 'extensions/mcp-events/src/http.ts',
  'extensions/mcp-events/src/service.ts', 'extensions/mcp-events/src/state.ts',
  'extensions/mcp-events/src/source-authority.ts', 'extensions/mcp-events/src/types.ts',
  'extensions/mcp-events/openclaw.plugin.json', request, 'src/plugins/service-mcp-events.ts',
  'src/gateway/server-methods/agent-id-shared.ts', 'src/gateway/server-methods/agent-runtime-authority.ts',
  'src/gateway/server-methods/cron-caller-scope.ts', 'src/shared/operator-scope-compat.ts',
  'packages/gateway-protocol/src/index.ts',
];
const hash = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));

function git(root, args) {
  return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1' } }).trimEnd();
}

function checkout(root) {
  assert.equal(realpathSync(git(root, ['rev-parse', '--show-toplevel'])), root);
  assert.equal(git(root, ['rev-parse', 'HEAD']), MCP_EVENTS_PIN);
  assert.equal(git(root, ['status', '--porcelain', '--untracked-files=no']), '');
  const files = git(root, ['ls-tree', '-rz', '--full-tree', MCP_EVENTS_PIN]).split('\0').filter(Boolean).map(item => {
    const [header, path] = item.split('\t');
    const [mode, type, blob] = header.split(' ');
    assert.equal(type, 'blob');
    assert.ok(['100644', '100755', '120000'].includes(mode));
    assert.ok(!isAbsolute(path) && !path.split('/').includes('..'));
    const file = join(root, path);
    const symlink = lstatSync(file).isSymbolicLink();
    assert.equal(symlink, mode === '120000');
    assert.ok(realpathSync(file).startsWith(root + sep));
    const bytes = symlink ? Buffer.from(readlinkSync(file)) : readFileSync(file);
    assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), blob, path);
    return { path, gitBlob: blob, sha256: hash(bytes) };
  });
  return {
    tracked: new Map(files.map(row => [row.path, row.sha256])),
    receipt: { verified: true, commit: MCP_EVENTS_PIN, tree: git(root, ['rev-parse', `${MCP_EVENTS_PIN}^{tree}`]),
      verifiedTrackedFiles: files.length, filesSha256: hash(JSON.stringify(files)) },
  };
}

// Generated host code is recorded verbatim. It only joins the two actual source entrypoints.
const hostCode = `
globalThis.__captureAudit = [];
globalThis.__deferredCalls = [];
globalThis.__fixture = undefined;
globalThis.__registeredFactory = undefined;
globalThis.__registration = undefined;
const configuration = { agents: { list: [{ id: 'fixture-agent' }] } };
const registry = { descriptors: () => [{ owner: { kind: 'plugin', pluginId: 'mcp-events' } }] };
const client = { connect: { scopes: [] } };
globalThis.__gatewayContext = { getRuntimeConfig: () => configuration, getGatewayMethodRegistry: () => registry };
globalThis.__api = {
  registrationMode: 'discovery',
  registerTool(factory, options) {
    globalThis.__registeredFactory = factory;
    globalThis.__registration = { mode: this.registrationMode, names: options.names, contextVersion: factory.contextVersion,
      factoryCreateInvoked: false, callbackExecuteInvoked: false };
  },
  runtime: { gateway: { async request(method, params) {
    const current = globalThis.__fixture;
    current.gatewayRequest = { method, params: JSON.parse(JSON.stringify(params)) };
    await globalThis.__gatewayHandler({ params, client, context: globalThis.__gatewayContext,
      respond(ok, payload) { current.gatewayResponse = { ok, payload }; } });
    if (current.gatewayResponse?.ok !== true) throw Error('ordinary catalog fixture did not complete');
    current.gatewayResult = current.gatewayResponse.payload;
    return current.gatewayResult;
  } } },
};
globalThis.__createTool = () => {
  const context = { agentId: 'fixture-agent', assertInvocationCurrent() {
    globalThis.__fixture.trace.push({ kind: 'fixture-invocation-current' });
  } };
  globalThis.__fixture.context = { agentId: context.agentId, assertInvocationCurrentType: typeof context.assertInvocationCurrent };
  globalThis.__tool = globalThis.__registeredFactory.create(context);
  globalThis.__registration.factoryCreateInvoked = true;
};
globalThis.__runTool = async () => {
  const current = globalThis.__fixture;
  current.callbackInput = JSON.parse(JSON.stringify(current.input));
  current.callbackResult = await globalThis.__tool.execute('ordinary-' + current.id, current.input);
  globalThis.__registration.callbackExecuteInvoked = true;
  current.detailsIsGatewayResult = current.callbackResult.details === current.gatewayResult;
  current.rawInputAfter = JSON.parse(JSON.stringify(current.input));
  current.remotePageAfter = JSON.parse(JSON.stringify(current.page));
};
`;

class McpEventsHarness extends FactoryHarness {
  constructor(root, tracked) {
    super(root, tracked, { allowedSources: wholeSources });
    // Default VM microtasks allow awaiting the unchanged async callbacks from Node.
    this.context = vm.createContext({ Buffer, __platform: { isDeepStrictEqual } }, { codeGeneration: { strings: false, wasm: false } });
    new vm.Script(hostCode).runInContext(this.context, { timeout: 1000 });
    this.sourceRecords = new Map();
    this.importBindings = new Map();
  }

  bytes(path) {
    const bytes = readFileSync(join(this.root, path));
    assert.equal(hash(bytes), this.tracked.get(path), path);
    return bytes;
  }

  module(file) {
    const path = relative(this.root, file);
    assert.ok(wholeSources.includes(path), `unconfigured whole-source module ${path}`);
    if (!this.sourceRecords.has(path)) {
      const bytes = this.bytes(path);
      const executable = stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false });
      this.sourceRecords.set(path, { path, sha256: hash(bytes), executed: true, wholeModule: true,
        transformation, executableSha256: hash(executable) });
    }
    return super.module(file);
  }

  binding(importer, specifier, kind, exports, code, extra = {}) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, {
      importer, specifier, kind, exports, ...extra, generatedCode: code, generatedSha256: hash(code),
    });
    return this.synthetic('capture:mcp-events:' + key, code);
  }

  source(importer, specifier, path) {
    const key = importer + ':' + specifier;
    if (!this.importBindings.has(key)) this.importBindings.set(key, { importer, specifier,
      kind: 'whole-source-module', source: path, sourceSha256: this.tracked.get(path) });
    return this.module(join(this.root, path));
  }

  deferred(importer, specifier, exports, source) {
    const code = exports.map(name => `export function ${name}(){globalThis.__deferredCalls.push(${JSON.stringify({ importer, specifier, export: name })});throw Error('uninvoked MCP Events dependency: ${name}');}`).join('\n');
    return this.binding(importer, specifier, 'uninvoked-dependency-facade', exports, code, { source, sourceExecuted: false });
  }

  constant(source, name) {
    const text = this.bytes(source).toString();
    const match = new RegExp('^export const ' + name + ' = ("[^"\\n]*");$', 'm').exec(text);
    assert.ok(match, `source constant ${source}:${name}`);
    return { name, value: JSON.parse(match[1]), source, sourceSha256: this.tracked.get(source),
      literalSha256: hash(match[1]) };
  }

  import(specifier, parent) {
    const importer = relative(this.root, parent);
    if (parent.startsWith('capture:mcp-events:') && specifier === 'capture:source:' + record) return this.module(join(this.root, record));
    if (importer === entry && specifier === 'openclaw/plugin-sdk/plugin-entry') return this.source(importer, specifier, pluginEntry);
    if ((importer === entry && specifier === 'openclaw/plugin-sdk/string-coerce-runtime') ||
      (importer === gateway && specifier === '@openclaw/normalization-core/record-coerce')) {
      const exports = importer === entry ? ['asOptionalRecord'] : ['isRecord', 'isStringArray'];
      return this.binding(importer, specifier, 'whole-source-export-alias', exports,
        'export {' + exports.join(',') + '} from ' + JSON.stringify('capture:source:' + record) + ';',
        { source: record, sourceSha256: this.tracked.get(record) });
    }
    if (importer === pluginEntry && specifier === './lazy-value.js') return this.source(importer, specifier, lazy);
    if (importer === pluginEntry && specifier === '../plugins/capability-provider.types.js') return this.source(importer, specifier, capabilityTypes);
    if (importer === pluginEntry && specifier === '../plugins/config-schema.js') return this.deferred(importer, specifier,
      ['emptyPluginConfigSchema', 'buildJsonPluginConfigSchema', 'buildPluginConfigSchema'], 'src/plugins/config-schema.ts');
    if (importer === entry && specifier === './src/config.js') return this.deferred(importer, specifier, ['resolveMcpEventsConfig'], 'extensions/mcp-events/src/config.ts');
    if (importer === entry && specifier === './src/http.js') return this.deferred(importer, specifier, ['createCallbackHandler'], 'extensions/mcp-events/src/http.ts');
    if (importer === entry && specifier === './src/service.js') return this.deferred(importer, specifier, ['McpEventsService'], 'extensions/mcp-events/src/service.ts');
    if (importer === entry && specifier === './src/protocol.js') {
      const constants = ['CALLBACK_PREFIX', 'MCP_EVENTS_PROFILE'].map(name => this.constant(protocol, name));
      return this.binding(importer, specifier, 'source-constant-facade', constants.map(row => row.name),
        constants.map(row => `export const ${row.name}=${JSON.stringify(row.value)};`).join('\n'), { constants, sourceExecuted: false });
    }
    if (importer === gateway && specifier === 'node:util') return this.binding(importer, specifier, 'actual-platform-builtin', ['isDeepStrictEqual'],
      'export const isDeepStrictEqual=globalThis.__platform.isDeepStrictEqual;', { platform: 'node:util.isDeepStrictEqual' });
    if (importer === gateway && specifier === '../../../packages/gateway-protocol/src/index.js') return this.binding(importer, specifier,
      'uninvoked-error-protocol-facade', ['ErrorCodes', 'errorShape'],
      `export const ErrorCodes={}; export function errorShape(){globalThis.__deferredCalls.push({kind:'uninvoked-error-protocol'});throw Error('uninvoked error shape');}`,
      { source: 'packages/gateway-protocol/src/index.ts', sourceExecuted: false });
    if (importer === gateway && specifier === '../../agents/mcp-event-request.js') {
      const constant = this.constant(request, 'MCP_EVENTS_PROTOCOL_VERSION');
      return this.binding(importer, specifier, 'successful-request-fixture', ['MCP_EVENTS_PROTOCOL_VERSION', 'requestMcpEvent'], `
export const MCP_EVENTS_PROTOCOL_VERSION=${JSON.stringify(constant.value)};
export async function requestMcpEvent(params) {
  const current=globalThis.__fixture;
  current.protocolRequests.push(JSON.parse(JSON.stringify(params)));
  if(params.method==='server/discover') return {supportedVersions:[MCP_EVENTS_PROTOCOL_VERSION],capabilities:{events:{}}};
  if(params.method==='events/list') return current.page;
  throw Error('unconfigured ordinary protocol fixture');
}`, { constant, source: request, sourceExecuted: false, network: false });
    }
    if (importer === gateway && specifier === '../../plugins/service-mcp-events.js') return this.binding(importer, specifier,
      'fixture-connection', ['prepareMcpEventConnection'], `
export async function prepareMcpEventConnection(params) {
  const current=globalThis.__fixture;
  current.preparedConnection=JSON.parse(JSON.stringify(params));
  current.preparedConnection.assertCurrentType=typeof params.assertCurrent;
  return {server:{kind:'successful-catalog-fixture'},assertCurrent:params.assertCurrent,
    release(){current.connectionReleases++;}};
}`, { source: 'src/plugins/service-mcp-events.ts', sourceExecuted: false });
    if (importer === gateway && specifier === '../../shared/operator-scope-compat.js') return this.binding(importer, specifier,
      'stable-host-context-facade', ['operatorScopeSatisfied'],
      `export function operatorScopeSatisfied(){globalThis.__fixture.trace.push({kind:'fixture-host-scope'});return true;}`,
      { source: 'src/shared/operator-scope-compat.ts', sourceExecuted: false });
    if (importer === gateway && specifier === './agent-id-shared.js') return this.binding(importer, specifier,
      'configured-agent-fixture', ['resolveAgentIdOrRespondError'], `
export function resolveAgentIdOrRespondError(params){
  globalThis.__fixture.agentResolution=JSON.parse(JSON.stringify(params));
  return {agentId:params.rawAgentId};
}`, { source: 'src/gateway/server-methods/agent-id-shared.ts', sourceExecuted: false });
    if (importer === gateway && specifier === './agent-runtime-authority.js') return this.binding(importer, specifier,
      'stable-host-context-facade', ['assertActiveAgentRuntimeAuthority'],
      `export function assertActiveAgentRuntimeAuthority(){globalThis.__fixture.trace.push({kind:'fixture-runtime-context'});}`,
      { source: 'src/gateway/server-methods/agent-runtime-authority.ts', sourceExecuted: false });
    if (importer === gateway && specifier === './cron-caller-scope.js') return this.binding(importer, specifier,
      'stable-host-context-facade', ['readCronCallerScope'],
      `export function readCronCallerScope(){globalThis.__fixture.trace.push({kind:'fixture-caller-context'});return undefined;}`,
      { source: 'src/gateway/server-methods/cron-caller-scope.ts', sourceExecuted: false });
    throw Error(`unconfigured MCP Events import ${importer}:${specifier}`);
  }

  run(code) { return new vm.Script(code).runInContext(this.context, { timeout: 1000 }); }
}

function vectors() {
  const event = (name, overrides = {}) => ({ name, delivery: ['webhook'], inputSchema: true, payloadSchema: false, ...overrides });
  const row = (id, page, input = { serverName: 'fixture-events' }) => ({ id, page, input });
  return [
    row('empty', { events: [] }),
    row('ordered-descriptors', { events: [
      event('zeta.changed', { description: 'Zeta 描述', delivery: ['poll', 'webhook', 'stream'],
        inputSchema: { type: 'object', properties: { document_id: { type: 'string' } }, required: ['document_id'], additionalProperties: false }, payloadSchema: true, extra: 'not catalog output' }),
      event('hidden.change', { delivery: ['poll'] }),
      event('alpha.changed', { inputSchema: false, payloadSchema: { type: 'object', properties: { rows: { type: 'array', items: { type: 'string' } } } } }),
      event('zeta.changed', { delivery: ['webhook', 'webhook'] }),
    ], nextCursor: 'ordinary-next', extra: { ignored: true } }),
    row('boolean-object-schemas', { events: [
      event('boolean.true'), event('boolean.false', { inputSchema: false, payloadSchema: true }),
      event('object.schemas', { description: '', inputSchema: {}, payloadSchema: { $defs: { item: { const: '界😀' } }, $ref: '#/$defs/item' } }),
    ] }),
    row('unicode-page-1', { events: [event('页一')], nextCursor: '下一页/😀?opaque=+%2F\t' }),
    row('unicode-page-2', { events: [event('页二')], nextCursor: '最后/界+==' }, { serverName: 'fixture-events', cursor: '下一页/😀?opaque=+%2F\t' }),
    row('raw-server-name', { events: [event('raw.changed')] }, { serverName: '  fixture 事件 😀  ', cursor: '\t cursor/界😀 +== \n' }),
    row('ascii-description', { events: [event('ascii.changed', { description: 'A'.repeat(5000) })] }),
    row('emoji-description', { events: [event('emoji.changed', { description: 'x'.repeat(4095) + '😀 ordinary tail' })] }),
    row('thousand-events', { events: Array.from({ length: 1000 }, (_, index) => event(`event.${String(index).padStart(4, '0')}`)), nextCursor: '1000/下一页' }),
  ];
}

export async function captureMcpEvents(source = fixedRoot) {
  assert.equal(process.versions.node, '24.22.1', 'use the fixed supported capture runtime');
  assert.equal(realpathSync(process.execPath), realpathSync(fixedNode));
  const root = realpathSync(source);
  assert.equal(root, realpathSync(fixedRoot));
  const before = checkout(root);
  assert.equal(before.receipt.verifiedTrackedFiles, 58558);
  const harness = new McpEventsHarness(root, before.tracked);
  await harness.load(entry);
  harness.run('globalThis.__entry=globalThis.__exports.default;globalThis.__entry.register(globalThis.__api);');
  await harness.load(gateway);
  harness.run('globalThis.__gatewayHandler=globalThis.__exports.mcpEventsHandlers["mcp.events.list"];');
  const observations = [];
  let tool;
  for (const recipe of vectors()) {
    const rawInput = plain(recipe.input);
    harness.run(`globalThis.__fixture=${JSON.stringify({ ...recipe, trace: [], protocolRequests: [], connectionReleases: 0 })};globalThis.__createTool();`);
    const metadata = harness.call('({name:__tool.name,label:__tool.label,description:__tool.description,parameters:__tool.parameters,executeObserved:typeof __tool.execute==="function"})');
    if (tool) assert.deepEqual(metadata, tool);
    else tool = metadata;
    await harness.run('globalThis.__runTool()');
    const result = harness.call('globalThis.__fixture');
    assert.deepEqual(result.rawInputAfter, rawInput, recipe.id);
    assert.deepEqual(result.remotePageAfter, recipe.page, recipe.id);
    observations.push({ id: recipe.id, rawInput, callbackInput: result.callbackInput, rawInputAfter: result.rawInputAfter,
      context: result.context, remotePage: recipe.page, remotePageAfter: result.remotePageAfter,
      gatewayRequest: result.gatewayRequest, preparedConnection: result.preparedConnection,
      agentResolution: result.agentResolution, protocolRequests: result.protocolRequests,
      gatewayResponse: result.gatewayResponse, callbackResult: result.callbackResult,
      detailsIsGatewayResult: result.detailsIsGatewayResult, connectionReleases: result.connectionReleases, trace: result.trace });
  }
  for (const path of provenancePaths) harness.sourceRecords.set(path, {
    path, sha256: hash(harness.bytes(path)), executed: false, provenanceOnly: true,
  });
  const after = checkout(root);
  assert.deepEqual(before.receipt, after.receipt);
  return {
    referenceCommit: MCP_EVENTS_PIN,
    runtime: { node: process.versions.node, v8: process.versions.v8, platform: process.platform, arch: process.arch,
      executable: fixedNode, executableSha256: hash(readFileSync(realpathSync(process.execPath))) },
    exporterSha256: hash(readFileSync(fileURLToPath(import.meta.url))),
    harness: { path: 'scripts/openclaw/capture-recipes.mjs', sha256: hash(readFileSync(new URL('./capture-recipes.mjs', import.meta.url))) },
    sourceTree: { before: before.receipt, after: after.receipt },
    sourceRecords: [...harness.sourceRecords.values()].sort((a, b) => a.path.localeCompare(b.path)),
    importBindings: [...harness.importBindings.values()],
    hostBinding: { kind: 'synthetic-host-registration-context-and-gateway-bridge', generatedCode: hostCode, generatedSha256: hash(hostCode),
      platformBindings: ['Buffer.byteLength', 'node:util.isDeepStrictEqual'] },
    deferredCalls: harness.call('globalThis.__deferredCalls'),
    registration: harness.call('globalThis.__registration'), tool, vectors: observations,
    boundaries: {
      wholeFactoryAndCallback: true, wholeGatewayHandlerAndPrivateProjection: true,
      hostRegistrationApi: 'fixture', connectionAndProtocolRequests: 'fixture', stableCallerAndRuntimeContext: 'fixture',
      productionPluginActivation: false, productionConfigParsing: false, productionTransport: false,
      subscriptionService: false, callbackHttpRoute: false, scheduler: false, durableIngress: false, hostIntegration: false,
      activationRequirement: 'Production enablement/config validation and plugin-owned Gateway registration are separate. callbackOrigin is required by plugin config; tool-only registration does not prove full activation.',
      hostBlocker: 'gsmlg-opt/backplane#132: public caller-owned MCP Events API is unavailable; this independent reference capture adds no host implementation.',
      limits: 'Ordinary source callbacks and one-page descriptor projection only; no subscription, remote network, production authority behavior, storage capacity or whole-reference equivalence evidence.',
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [, , source = fixedRoot, output] = process.argv;
  assert.ok(output, 'usage: capture-mcp-events.mjs /tmp/openclaw-488631c output.json');
  const capture = await captureMcpEvents(source);
  writeFileSync(output, JSON.stringify(capture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ output, vectors: capture.vectors.length,
    executedWholeModules: capture.sourceRecords.filter(row => row.executed).length,
    provenanceOnlySources: capture.sourceRecords.filter(row => !row.executed).length,
    trackedBlobsBeforeAndAfter: capture.sourceTree.before.verifiedTrackedFiles }) + '\n');
}
