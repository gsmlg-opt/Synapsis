// Ordinary cache policy observations from complete pinned modules.
// Reuses the public Brave harness; HTTP/platform and time remain explicit fixtures.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  BRAVE_REFERENCE_CLOCK, BRAVE_REFERENCE_PIN, BraveCapture,
} from './capture-brave-search-filters.mjs';

const factory = 'extensions/brave/src/brave-web-search-provider.ts';
const shared = 'src/agents/tools/web-shared.ts';
const originMs = Date.parse(BRAVE_REFERENCE_CLOCK);
const digest = value => createHash('sha256').update(value).digest('hex');
const plain = value => JSON.parse(JSON.stringify(value));
const sort = values => [...values].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const defaultPolicy = { ttlMs: 900_000, timeoutMs: 30_000, defaultCount: 5 };

function publicRecipes() {
  const step = (elapsedMs, policy = {}) => ({
    elapsedMs, policy: { ...defaultPolicy, ...policy },
    arguments: { query: 'ordinary cache policy', count: 2 },
  });
  return ['web', 'llm-context'].flatMap(mode => [
    { id: `${mode}-policy-independent-identity`, mode, steps: [
      step(0), step(1, { timeoutMs: 10_000 }),
      step(2, { ttlMs: 60_000, timeoutMs: 10_000, defaultCount: 9 }),
      step(3, { defaultCount: 3 }),
    ] },
    { id: `${mode}-zero-ttl-bypass`, mode, steps: [
      step(0), step(1_000, { ttlMs: 0 }), step(1_001, { ttlMs: 0 }), step(1_002),
    ] },
    { id: `${mode}-shorter-caller-refresh`, mode, steps: [
      step(0), step(59_999, { ttlMs: 60_000 }), step(60_000, { ttlMs: 60_000 }),
      step(60_001), step(120_000), step(120_001),
    ] },
    { id: `${mode}-stored-expiry-ceiling`, mode, steps: [
      step(0, { ttlMs: 60_000 }), step(59_999), step(60_000), step(60_001),
    ] },
  ]);
}

async function publicGroup(root, recipe) {
  const capture = new BraveCapture(root);
  const module = capture.source(factory);
  await capture.evaluate(module);
  const steps = [];
  for (const item of recipe.steps) {
    capture.nowMs = originMs + item.elapsedMs;
    const setup = {
      config: { plugins: { entries: { brave: { config: { webSearch: {
        apiKey: 'fixture-brave-key', baseUrl: 'http://127.0.0.1:18181/proxy', mode: recipe.mode,
      } } } } } },
      searchConfig: {
        cacheTtlMinutes: item.policy.ttlMs / 60_000,
        timeoutSeconds: item.policy.timeoutMs / 1_000,
        maxResults: item.policy.defaultCount,
      },
    };
    // Different factory tools share the actual complete module's private SEARCH_CACHE.
    const tool = module.namespace.createBraveWebSearchProvider().createTool(setup);
    const args = plain(item.arguments);
    const before = plain(args);
    const count = capture.requests.length;
    const result = plain(await tool.execute(args));
    assert.deepEqual(args, before, 'public callback preserves raw arguments');
    assert.equal(result.provider, 'brave', 'ordinary public callback succeeds');
    const requests = capture.requests.slice(count);
    assert.ok(requests.length <= 1);
    steps.push({ ...item, setup, request: requests[0] ?? null,
      cached: result.cached === true, cumulativeRequests: capture.requests.length, result });
  }
  return { capture, group: { id: recipe.id, mode: recipe.mode, steps, audit: capture.audit } };
}

function helperRecipes() {
  const put = (key, value, elapsedMs = 0, ttlMs = 900_000) => ({
    operation: 'put', key, value: { text: value }, elapsedMs, ttlMs,
  });
  const get = (key, elapsedMs = 0, ttlMs) => ({
    operation: 'get', key, elapsedMs, ...(ttlMs === undefined ? {} : { ttlMs }),
  });
  const fill = () => Array.from({ length: 100 }, (_, index) => put(`k${index}`, `value-${index}`));
  return [
    { id: 'caller-age-and-zero-retain', steps: [
      put('original', 'original', 0, 900),
      get('original', 99, 100), get('original', 100, 100), get('original', 100, 900),
      get('original', 100, 0), put('original', 'disabled', 100, 0), get('original', 100),
      get('original', 900, 900),
    ] },
    { id: 'stored-expiry-ceiling', steps: [
      put('short', 'short', 0, 100), get('short', 99, 900), get('short', 100, 900),
      put('short', 'replacement', 100, 100), get('short', 199), get('short', 200),
    ] },
    { id: 'update-preserves-insertion-order', steps: [
      put('a', 'first'), put('b', 'second', 1), put('a', 'updated', 2), get('a', 3),
      put('c', 'third', 4), get('b', 4),
    ] },
    { id: 'expiry-is-key-local', steps: [
      put('expired-neighbor', 'old', 0, 10), put('live', 'live', 1, 100),
      get('live', 10), put('new', 'new', 11, 100), get('expired-neighbor', 11),
      get('live', 11),
    ] },
    { id: 'capacity-prunes-before-existing-update', steps: [
      ...fill(), get('k0', 1), put('k100', 'new', 2), put('k50', 'updated', 3),
      get('k50', 4),
    ] },
    { id: 'capacity-oldest-reinsert-appends', steps: [
      ...fill(), put('k0', 'updated oldest', 1), get('k0', 2),
    ] },
    { id: 'capacity-zero-ttl-preserves-state', steps: [
      ...fill(), get('k0', 1, 0), put('new', 'disabled', 1, 0),
      put('k50', 'disabled overwrite', 1, 0), get('k50', 1),
    ] },
  ];
}

async function helperGroup(root, recipe) {
  const capture = new BraveCapture(root);
  const module = capture.source(shared);
  await capture.evaluate(module);
  const cache = new Map();
  const steps = [];
  for (const operation of recipe.steps) {
    capture.nowMs = originMs + operation.elapsedMs;
    let result = null;
    if (operation.operation === 'put') {
      module.namespace.writeCache(cache, operation.key, plain(operation.value), operation.ttlMs);
    } else {
      result = module.namespace.readCache(cache, operation.key, operation.ttlMs);
    }
    const target = cache.get(operation.key);
    steps.push({ ...operation, result: result === null ? null : plain(result),
      state: {
        size: cache.size, keys: [...cache.keys()],
        target: target ? {
          value: plain(target.value),
          insertedAtMs: target.insertedAt - originMs,
          expiresAtMs: target.expiresAt - originMs,
        } : null,
      },
    });
  }
  return { capture, group: { id: recipe.id, steps } };
}

export async function captureSearchCachePolicy(root = '/tmp/openclaw-488631c') {
  const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  assert.equal(head, BRAVE_REFERENCE_PIN);
  const publicGroups = [], helperGroups = [];
  const sources = new Map(), aliases = new Map(), stubs = new Map();
  const merge = capture => {
    for (const [key, value] of capture.sources) {
      const old = sources.get(key);
      sources.set(key, { ...value, executed: value.executed || old?.executed === true });
    }
    for (const [key, value] of capture.aliases) aliases.set(key, value);
    for (const [key, value] of capture.stubBindings) stubs.set(key, value);
  };
  for (const recipe of publicRecipes()) {
    const { capture, group } = await publicGroup(root, recipe);
    merge(capture); publicGroups.push(group);
  }
  for (const recipe of helperRecipes()) {
    const { capture, group } = await helperGroup(root, recipe);
    merge(capture); helperGroups.push(group);
  }
  return {
    version: 1, pin: BRAVE_REFERENCE_PIN, runtime: process.version, clock: BRAVE_REFERENCE_CLOCK,
    harness: { path: 'scripts/openclaw/capture-search-cache-policy.mjs',
      sha256: digest(readFileSync(new URL(import.meta.url))) },
    harnessDependencies: [{ path: 'scripts/openclaw/capture-brave-search-filters.mjs',
      sha256: digest(readFileSync(new URL('./capture-brave-search-filters.mjs', import.meta.url))),
      reuse: 'exported BraveCapture; unchanged complete-source loader, SDK facades and platform bindings' }],
    invocations: [
      'createBraveWebSearchProvider().createTool(setup).execute(arguments)',
      'web-shared.ts namespace.readCache(Map,key,ttlMs)',
      'web-shared.ts namespace.writeCache(Map,key,value,ttlMs)',
    ],
    transformation: 'node:module.stripTypeScriptTypes(mode=transform,sourceMap=false)',
    boundaries: {
      factoryInvoked: true, callbackInvoked: true, fullSourceModules: true,
      bodyProjections: false, actualSharedCache: true, helperFunctionsInvoked: true,
      productionNetworkInvoked: false,
      clock: 'Date construction and Date.now use a synthetic clock; elapsedMs is relative to clock',
      fixtureEnvironment: {},
      limits: [
        'HTTP wrappers, response parsing, endpoint classification and deadline machinery are inherited fixture bindings',
        'literal fixture config does not exercise secret resolution',
        'factory callbacks do not prove plugin discovery, registration or runtime assembly',
        'direct helper Maps are isolated fixture instances, separate from the callback module private SEARCH_CACHE',
        'clock-controlled observations do not prove production wall-clock rollover or scheduling',
        'only ordinary successful callbacks and cache lifecycle operations are captured',
      ],
    },
    sources: sort(sources.values()), aliases: sort(aliases.values()), stubs: sort(stubs.values()),
    publicGroups, helperGroups,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root = '/tmp/openclaw-488631c', output] = process.argv.slice(2);
  const capture = await captureSearchCachePolicy(root);
  const json = JSON.stringify(capture, null, 2) + '\n';
  if (output) writeFileSync(output, json);
  else process.stdout.write(json);
}
