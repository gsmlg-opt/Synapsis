import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync,
  renameSync, rmSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Independently frozen positive literals. No product response, copied key
// algorithm, imported node:test suite or template fallback supplies expectations.
const repository = fileURLToPath(new URL('../../../', import.meta.url));
const ARCHIVE = '/tmp/synapsis-workflow183-70ivyzc0/lobster-2026.9.16.tgz';
const ARCHIVE_SHA = 'ef24c4e1eabb9d694f9e311826264dd6111566dcdc74d62ad0d13cdd6cda47e1';
const string = value => ({ type: 'string', value });
const ref = id => ({ type: 'reference', id });
const PATHS = [
  ['ascii', 'Session:Alpha', 'Session:Alpha', 'captured state', 'captured state/session_alpha.json'],
  ['collision-slash', 'A/B', 'A/B', 'captured state', 'captured state/a_b.json'],
  ['collision-colon', 'A:B', 'A:B', 'captured state', 'captured state/a_b.json'],
  ['unicode-filter', 'Résumé 雪 ABC😀', 'Résumé 雪 ABC😀', 'captured state', 'captured state/r_sum_abc.json'],
  ['dotted-i', 'İ', 'İ', 'captured state', 'captured state/i.json'],
  ['kelvin', 'K', 'K', 'captured state', 'captured state/k.json'],
  ['edge-underscores', '__Hello___World__', '__Hello___World__', 'captured state', 'captured state/hello_world.json'],
  ['retained-punctuation', 'V1.2-STATE', 'V1.2-STATE', 'captured state', 'captured state/v1.2-state.json'],
  ['tagged-string', string('Tagged KEY'), 'Tagged KEY', 'captured state', 'captured state/tagged_key.json'],
  ['tagged-lone-prefix', { type: 'string', utf16le: 'ANhBAA==' }, '\ud800A', 'captured state', 'captured state/a.json'],
  ['tagged-lone-middle', { type: 'string', utf16le: 'QQAA3EIA' }, 'A\udc00B', 'captured state', 'captured state/a_b.json'],
  ['boolean-true', true, true, 'captured state', 'captured state/true.json'],
  ['boolean-false', false, false, 'captured state', 'captured state/false.json'],
  ['finite-number', 42, 42, 'captured state', 'captured state/42.json'],
  ['finite-fraction', 1.5, 1.5, 'captured state', 'captured state/1.5.json'],
  ['relative-normalization', 'KEY', 'KEY', './state/../state cache//nested/.', 'state cache/nested/key.json'],
  ['absolute-spaces', 'KEY', 'KEY', '/tmp/state dir/a/../b', '/tmp/state dir/b/key.json'],
];
const TEXTS = [
  ['pretty-lf', '7b0a2020226f6b223a20747275650a7d0a', '{\n  "ok": true\n}\n'],
  ['pretty-crlf', '7b0d0a2020226f6b223a20747275650d0a7d0d0a', '{\r\n  "ok": true\r\n}\r\n'],
  ['unicode', 'e99baaf09f98800a', '雪😀\n'],
  ['bom', 'efbbbf7b226f6b223a747275657d0a', '\uFEFF{"ok":true}\n'],
  ['empty', '', ''],
  ['raw-text', '72617720737461746520746578740a', 'raw state text\n'],
  ['whitespace', '2020090a', '  \t\n'],
];
const HEAP = { version: 1, next_id: 3, nodes: {
  '1': { type: 'object', keys: ['type'], fields: { type: string('string') } },
  '2': { type: 'object', keys: ['private'], fields: {
    private: { type: 'string', utf16le: 'ANg=' },
  } },
} };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const receipt = (id, outcome, extra = {}) =>
  ({ type: 'result', id, result: 'ok', outcome, ...extra, cacheEntries: 1 });

function files(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).flatMap(entry => {
    const path = join(prefix, entry.name);
    if (entry.isDirectory()) return files(root, path);
    assert.ok(entry.isFile(), path);
    return [path];
  }).sort();
}

test('source oracle: whole pinned original keyToPath and actual filesystem UTF8 read', async t => {
  // Everything needed by this test is local to it. --test-name-pattern='source
  // oracle:' works with no staged-root environment or product helper import.
  assert.equal(sha(readFileSync(ARCHIVE)), ARCHIVE_SHA);
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-state-original-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  execFileSync('tar', ['-xzf', resolve(ARCHIVE), '-C', temporary],
    { timeout: 10_000, maxBuffer: 1024 * 1024 });
  const original = join(temporary, 'package');
  const paths = files(original);
  assert.equal(paths.length, 156);
  assert.equal(paths.filter(path => path.startsWith('dist/src/') && path.endsWith('.js')).length, 74);
  const pkg = JSON.parse(readFileSync(join(original, 'package.json'), 'utf8'));
  assert.equal(pkg.name, '@clawdbot/lobster');
  assert.equal(pkg.version, '2026.9.16');
  const store = readFileSync(join(original, 'dist/src/state/store.js'));
  assert.equal(sha(store), '8a0e750ccbf3e44135e96d82f4836d474369e8401feb8b498a77165afa29e77c');
  assert.equal(store.length, 27175);
  assert.equal(store.toString('utf8').split('\n').length, 751);
  assert.equal(sha(readFileSync(join(original, 'dist/src/state/atomic_file.js'))),
    '87870c3439c4c8da907ada7f9a7412d5f84cc52e5225bb0deeab19b416c7d3b5');
  // Import the complete unchanged original module, with its original sibling.
  // No extraction or rewriting of keyToPath itself occurs.
  const { keyToPath } = await import(pathToFileURL(join(original, 'dist/src/state/store.js')));
  assert.equal(PATHS.length, 17);
  for (const [id, , originalKey, directory, expected] of PATHS) {
    assert.equal(keyToPath(directory, originalKey), expected, id);
  }
  assert.equal(TEXTS.length, 7);
  for (const [id, hex, expected] of TEXTS) {
    const path = join(temporary, id + ' state bytes.txt');
    writeFileSync(path, Buffer.from(hex, 'hex'));
    // The original state reader uses fsp.readFile(path, "utf8"). This is its
    // actual filesystem decoding boundary, not a claimed raw-text public API.
    assert.equal(await readFile(path, 'utf8'), expected, id);
  }
  t.diagnostic(JSON.stringify({ archiveRegularFiles: 156, originalJavaScriptFiles: 74,
    wholeOriginalStoreBytes: 27175, wholeOriginalStoreLines: 751,
    originalKeyCalls: 17, filesystemUtf8Reads: 7, sourceTransformed: false }));
});

async function* frames(stream) {
  let pending = Buffer.alloc(0);
  for await (const chunk of stream) {
    pending = Buffer.concat([pending, chunk]);
    let lf;
    while ((lf = pending.indexOf(10)) !== -1) {
      const raw = pending.subarray(0, lf);
      pending = pending.subarray(lf + 1);
      yield JSON.parse(raw.toString('utf8'));
    }
  }
  assert.equal(pending.length, 0);
}

function bounded(promise, label) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(label + ' timed out')), 20_000);
  })]).finally(() => clearTimeout(timer));
}

function relocatedHelper(t) {
  const staged = process.env.SYNAPSIS_WORKFLOW_STATE_HELPER_ROOT;
  assert.ok(staged && isAbsolute(staged), 'supply absolute SYNAPSIS_WORKFLOW_STATE_HELPER_ROOT');
  const temporary = mkdtempSync(join(tmpdir(), 'synapsis-state-relocation-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const assembled = join(temporary, 'assembled complete helper');
  const relocated = join(temporary, 'relocated complete helper');
  cpSync(staged, assembled, { recursive: true });
  renameSync(assembled, relocated);
  assert.equal(existsSync(assembled), false);
  const paths = files(staged);
  assert.equal(paths.length, 599);
  assert.deepEqual(files(relocated), paths);
  assert.ok(paths.includes('schema-stdio.mjs'));
  assert.ok(paths.includes('schema-worker.mjs'));
  for (const path of paths) assert.deepEqual(readFileSync(join(relocated, path)), readFileSync(join(staged, path)), path);
  return join(relocated, 'schema-stdio.mjs');
}

async function helperSession(t, helper, kind, label) {
  const executable = realpathSync(process.execPath);
  const child = spawn(process.execPath, [helper], { stdio: ['pipe', 'pipe', 'pipe'] });
  const stderr = [];
  child.stderr.on('data', bytes => stderr.push(bytes));
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const iterator = frames(child.stdout);
  const next = async () => {
    const frame = await bounded(iterator.next(), 'helper frame');
    assert.equal(frame.done, false, Buffer.concat(stderr).toString('utf8'));
    return frame.value;
  };
  const pid = child.pid;
  const assertProcess = () => {
    assert.ok(Number.isSafeInteger(pid));
    assert.equal(child.pid, pid);
    assert.equal(child.exitCode, null);
    assert.equal(existsSync('/proc/' + pid), true);
    assert.equal(realpathSync('/proc/' + pid + '/exe'), executable);
  };
  async function fulfill(request, expected) {
    const snapshot = JSON.stringify({ request, heap: HEAP });
    child.stdin.write(JSON.stringify({ type: 'request', timeoutMs: 15000, request, heap: HEAP }) + '\n');
    const actual = await next();
    assertProcess();
    assert.equal(JSON.stringify({ request, heap: HEAP }), snapshot);
    assert.deepEqual(actual, expected, request.id);
    return actual;
  }
  let requests = 0;
  try {
    assert.deepEqual(await next(), { type: 'ready', version: 1, profile: 'ajv-8.20.0-draft07' });
    assertProcess();
    await fulfill({ id: label + ':compile', kind: 'compile_schema', schema: ref('1') },
      receipt(label + ':compile', 'compiled'));
    if (kind === 'state_key_path') {
      for (const [id, key, , state_dir, lexical_path] of PATHS) {
        const correlated = label + ':path:' + id;
        await fulfill({ id: correlated, kind, key, state_dir },
          receipt(correlated, 'state_path', { lexical_path }));
        requests++;
      }
    } else {
      for (const [id, hex, expected] of TEXTS) {
        const correlated = label + ':decode:' + id;
        const request = { id: correlated, kind, bytes_base64: Buffer.from(hex, 'hex').toString('base64') };
        const actual = await fulfill(request, receipt(correlated, 'decoded', { value: string(expected) }));
        // Existing decode_template_file remains exactly the same successful API.
        const legacyId = correlated + ':legacy';
        await fulfill({ ...request, id: legacyId, kind: 'decode_template_file' },
          receipt(legacyId, 'decoded', { value: string(expected) }));
        await fulfill({ id: correlated + ':validate', kind: 'validate_response', schema: ref('1'), response: actual.value },
          receipt(correlated + ':validate', 'valid'));
        requests++;
      }
    }
    await fulfill({ id: label + ':validate', kind: 'validate_response', schema: ref('1'), response: string('ordinary') },
      receipt(label + ':validate', 'valid'));
    await fulfill({ id: label + ':render', kind: 'render_template', template: string('[{{.}}]'), item: string('雪😀') },
      receipt(label + ':render', 'rendered', { value: string('[雪😀]') }));
    await fulfill({ id: label + ':compile-reuse', kind: 'compile_schema', schema: ref('1') },
      receipt(label + ':compile-reuse', 'compiled'));
    assert.equal(requests, kind === 'state_key_path' ? 17 : 7);
  } finally {
    // The ordinary close is also required after a baseline success assertion
    // fails. No kill/cancel fallback is counted or exercised by these tests.
    child.stdin.write('{"type":"close"}\n');
    assert.deepEqual(await next(), { type: 'closed' });
    assert.deepEqual(await bounded(completion, 'normal helper exit'), { code: 0, signal: null });
    assert.equal((await bounded(iterator.next(), 'stdout completion')).done, true);
    assert.equal(existsSync('/proc/' + pid), false);
    assert.equal(Buffer.concat(stderr).toString('utf8'), '');
    t.diagnostic(JSON.stringify({ target: label, kind, executable,
      computeRequestsCompleted: requests, normalCloseAndExitObserved: true }));
  }
}

for (const [label, relocated] of [['source', false], ['relocated', true]]) {
  for (const kind of ['state_key_path', 'decode_state_text']) {
    test(label + ' helper: ' + kind + ' keeps the actual PID/cache and closes normally',
      { timeout: 120_000 }, async t => {
        const helper = relocated ? relocatedHelper(t) : join(repository, 'packages/tool-host/src/workflow/schema-stdio.mjs');
        await helperSession(t, helper, kind, label + ':' + kind);
      });
  }
}
