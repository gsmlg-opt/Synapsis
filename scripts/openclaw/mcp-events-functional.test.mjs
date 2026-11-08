// Dedicated ordinary catalog observations; no production service or network calls.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureMcpEvents, MCP_EVENTS_PIN } from './capture-mcp-events.mjs';

const root = process.env.OPENCLAW_MCP_EVENTS_SOURCE ?? '/tmp/openclaw-488631c';
const fixturePath = process.env.OPENCLAW_MCP_EVENTS_FIXTURE ?? new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/mcp-events.json', import.meta.url);
const capture = await captureMcpEvents(root);
const hash = value => createHash('sha256').update(value).digest('hex');
const vector = id => {
  const row = capture.vectors.find(item => item.id === id);
  assert.ok(row, id);
  return row;
};
const events = id => vector(id).callbackResult.details.events;

test('complete registered factory exposes the exact MCP Events browsing contract', () => {
  assert.equal(capture.referenceCommit, MCP_EVENTS_PIN);
  assert.deepEqual(capture.registration, { mode: 'discovery', names: ['mcp_events'], contextVersion: 2, factoryCreateInvoked: true, callbackExecuteInvoked: true });
  assert.deepEqual(capture.tool, {
    name: 'mcp_events', label: 'MCP Events',
    description: 'List webhook events and subscription argument schemas from a configured MCP server. Use the descriptors to create an Automation event source; this tool does not schedule or subscribe by itself. Pass nextCursor as cursor for another page.',
    parameters: {
      type: 'object', properties: {
        serverName: { type: 'string', minLength: 1, maxLength: 256 },
        cursor: { type: 'string', minLength: 1, maxLength: 16384 },
      }, required: ['serverName'], additionalProperties: false,
    }, executeObserved: true,
  });
  assert.equal(capture.tool.parameters.properties.action, undefined);
});

test('each successful callback discovers once, lists exactly one page and releases its fixture connection', () => {
  assert.equal(capture.vectors.length, 9);
  for (const row of capture.vectors) {
    assert.deepEqual(row.protocolRequests.map(item => item.method), ['server/discover', 'events/list'], row.id);
    assert.deepEqual(row.protocolRequests[1].params, row.rawInput.cursor === undefined ? {} : { cursor: row.rawInput.cursor }, row.id);
    assert.equal(row.connectionReleases, 1, row.id);
    assert.deepEqual(row.gatewayRequest, { method: 'mcp.events.list', params: { agentId: 'fixture-agent', ...row.rawInput } }, row.id);
    assert.equal(row.gatewayResponse.ok, true, row.id);
    assert.equal(row.context.agentId, 'fixture-agent');
    assert.equal(row.context.assertInvocationCurrentType, 'function');
  }
  assert.deepEqual(events('empty'), []);
  assert.deepEqual(vector('empty').callbackResult.details, { serverName: 'fixture-events', events: [] });
});

test('actual private Gateway projection keeps ordered webhook descriptors, duplicate names and exact schema data', () => {
  const rows = events('ordered-descriptors');
  assert.deepEqual(rows.map(row => row.name), ['zeta.changed', 'alpha.changed', 'zeta.changed']);
  assert.deepEqual(rows[0], {
    name: 'zeta.changed', description: 'Zeta 描述', delivery: ['poll', 'webhook', 'stream'],
    inputSchema: { type: 'object', properties: { document_id: { type: 'string' } }, required: ['document_id'], additionalProperties: false },
    payloadSchema: true,
  });
  assert.deepEqual(rows[1], {
    name: 'alpha.changed', delivery: ['webhook'], inputSchema: false,
    payloadSchema: { type: 'object', properties: { rows: { type: 'array', items: { type: 'string' } } } },
  });
  assert.deepEqual(rows[2], { name: 'zeta.changed', delivery: ['webhook', 'webhook'], inputSchema: true, payloadSchema: false });
  assert.deepEqual(Object.keys(vector('ordered-descriptors').callbackResult.details), ['serverName', 'events', 'nextCursor']);
  assert.deepEqual(events('boolean-object-schemas'), [
    { name: 'boolean.true', delivery: ['webhook'], inputSchema: true, payloadSchema: false },
    { name: 'boolean.false', delivery: ['webhook'], inputSchema: false, payloadSchema: true },
    { name: 'object.schemas', description: '', delivery: ['webhook'], inputSchema: {}, payloadSchema: { $defs: { item: { const: '界😀' } }, $ref: '#/$defs/item' } },
  ]);
});

test('opaque Unicode pagination stays explicit and raw server/cursor strings are forwarded intact', () => {
  const first = vector('unicode-page-1');
  const second = vector('unicode-page-2');
  assert.equal(first.callbackResult.details.nextCursor, '下一页/😀?opaque=+%2F\t');
  assert.equal(second.rawInput.cursor, first.callbackResult.details.nextCursor);
  assert.equal(second.callbackResult.details.nextCursor, '最后/界+==');
  assert.equal(second.protocolRequests.length, 2);
  assert.deepEqual(events('unicode-page-1').map(row => row.name), ['页一']);
  assert.deepEqual(events('unicode-page-2').map(row => row.name), ['页二']);
  const raw = vector('raw-server-name');
  assert.equal(raw.rawInput.serverName, '  fixture 事件 😀  ');
  assert.equal(raw.gatewayRequest.params.serverName, raw.rawInput.serverName);
  assert.equal(raw.callbackResult.details.serverName, raw.rawInput.serverName);
  assert.equal(raw.protocolRequests[1].params.cursor, '\t cursor/界😀 +== \n');
});

test('valid long descriptions expose exact UTF16 slice and escaped lone-surrogate JSON', () => {
  const ascii = vector('ascii-description');
  assert.equal(ascii.remotePage.events[0].description, 'A'.repeat(5000));
  assert.equal(events('ascii-description')[0].description, 'A'.repeat(4096));
  const emoji = vector('emoji-description');
  assert.equal(emoji.remotePage.events[0].description.isWellFormed(), true);
  const description = events('emoji-description')[0].description;
  assert.equal(description, 'x'.repeat(4095) + '\ud83d');
  assert.equal(description.length, 4096);
  assert.equal(emoji.callbackResult.content[0].text.includes('\\ud83d'), true);
  assert.equal(JSON.parse(emoji.callbackResult.content[0].text).events[0].description, description);
});

test('1000 ordinary descriptors remain one ordered bounded page', () => {
  const row = vector('thousand-events');
  assert.equal(row.remotePage.events.length, 1000);
  assert.ok(Buffer.byteLength(JSON.stringify(row.remotePage), 'utf8') < 1_048_576);
  assert.deepEqual(row.callbackResult.details.events.map(item => item.name), Array.from({ length: 1000 }, (_, index) => `event.${String(index).padStart(4, '0')}`));
  assert.equal(row.callbackResult.details.nextCursor, '1000/下一页');
  assert.equal(row.protocolRequests.length, 2);
});

test('actual callback emits exact JSON text/details and preserves input/page objects', () => {
  for (const row of capture.vectors) {
    assert.deepEqual(row.rawInputAfter, row.rawInput, row.id);
    assert.deepEqual(row.callbackInput, row.rawInput, row.id);
    assert.deepEqual(row.remotePageAfter, row.remotePage, row.id);
    assert.equal(row.detailsIsGatewayResult, true, row.id);
    assert.deepEqual(row.callbackResult.details, row.gatewayResponse.payload, row.id);
    assert.deepEqual(row.callbackResult.content, [{ type: 'text', text: JSON.stringify(row.gatewayResponse.payload) }], row.id);
  }
});

test('runtime, whole source bytes, executable hashes and every import boundary have explicit provenance', () => {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(capture.runtime.node, '24.22.1');
  assert.equal(capture.runtime.executableSha256, hash(readFileSync(realpathSync(process.execPath))));
  assert.equal(capture.exporterSha256, hash(readFileSync(new URL('./capture-mcp-events.mjs', import.meta.url))));
  assert.equal(capture.sourceTree.before.verifiedTrackedFiles, 58558);
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.sourceRecords.filter(row => row.executed).length, 6);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(root, row.path));
    assert.equal(hash(bytes), row.sha256, row.path);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(row.executableSha256, hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.path);
    } else assert.equal(row.provenanceOnly, true, row.path);
  }
  for (const facade of capture.importBindings.filter(row => row.generatedCode !== undefined)) assert.equal(facade.generatedSha256, hash(facade.generatedCode));
  assert.ok(capture.importBindings.some(row => row.importer.endsWith('mcp-events.ts') && row.specifier === '../../agents/mcp-event-request.js' && row.kind === 'successful-request-fixture'));
  assert.ok(capture.importBindings.some(row => row.kind === 'whole-source-export-alias' && row.source === 'packages/normalization-core/src/record-coerce.ts'));
  assert.equal(capture.deferredCalls.length, 0);
  assert.equal(capture.boundaries.productionPluginActivation, false);
  assert.equal(capture.boundaries.productionTransport, false);
  assert.equal(capture.boundaries.subscriptionService, false);
  assert.equal(capture.boundaries.scheduler, false);
  assert.equal(capture.boundaries.hostIntegration, false);
  assert.equal(capture.hostBinding.generatedSha256, hash(capture.hostBinding.generatedCode));
});

test('fresh full-source capture equals the frozen ordinary fixture exactly', () => {
  assert.deepEqual(capture, JSON.parse(readFileSync(fixturePath, 'utf8')));
});
