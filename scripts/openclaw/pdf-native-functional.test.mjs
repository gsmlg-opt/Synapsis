// Ordinary valid native helper executions and frozen-source/request comparison.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { test } from 'node:test';
import { PDF_NATIVE_PIN, PDF_NATIVE_SOURCE, runPdfNativeCapture } from './capture-pdf-native.mjs';

const root = process.env.OPENCLAW_PDF_SOURCE ?? '/tmp/openclaw-488631c';
const frozen = JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/pdf-native.json', import.meta.url)));
const capture = await runPdfNativeCapture(root);
const hash = value => createHash('sha256').update(value).digest('hex');

test('complete byte-verified original module reproduces the frozen ordinary callbacks', () => {
  assert.deepEqual(capture, frozen);
  assert.equal(capture.referencePin, PDF_NATIVE_PIN);
  const bytes = readFileSync(join(root, PDF_NATIVE_SOURCE));
  assert.deepEqual(bytes, execFileSync('git', ['show', `${PDF_NATIVE_PIN}:${PDF_NATIVE_SOURCE}`], { cwd: root }));
  assert.deepEqual(capture.sourceAudit, [{ path: PDF_NATIVE_SOURCE, sourceSha256: hash(bytes),
    executableSha256: hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })),
    wholeModule: true, executed: true }]);
  assert.equal(capture.harness.sha256, hash(readFileSync(new URL('./capture-pdf-native.mjs', import.meta.url))));
});

test('one and two PDF bodies preserve all base64 bytes and document-before-prompt order', () => {
  assert.deepEqual(capture.observations.map(row => row.id), [
    'anthropic-one', 'anthropic-two', 'gemini-one', 'gemini-two', 'gemini-model-escape',
  ]);
  for (const row of capture.observations) {
    const base64 = row.input.pdfs.map(pdf => pdf.base64);
    for (const value of base64) assert.equal(Buffer.from(value, 'base64').toString('base64'), value);
    if (row.protocol === 'anthropic') {
      assert.deepEqual(row.request.body, { model: row.input.modelId,
        max_tokens: row.input.maxTokens ?? 4096,
        messages: [{ role: 'user', content: [
          ...base64.map(data => ({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data } })),
          { type: 'text', text: row.input.prompt },
        ] }],
      });
    } else {
      assert.deepEqual(row.request.body, { contents: [{ role: 'user', parts: [
        ...base64.map(data => ({ inline_data: { mime_type: 'application/pdf', data } })),
        { text: row.input.prompt },
      ] }] });
    }
    assert.equal(row.result, 'First PDF analysis.');
    assert.equal(row.request.timeoutMs, 120000);
    assert.equal(row.releaseCount, 1);
  }
});

test('ordinary local custom bases and Gemini model escaping retain the observed URL', () => {
  const urls = Object.fromEntries(capture.observations.map(row => [row.id, row.request.url]));
  assert.deepEqual(urls, {
    'anthropic-one': 'https://api.anthropic.com/v1/messages',
    'anthropic-two': 'http://127.0.0.1:18181/anthropic/v1/messages',
    'gemini-one': 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent',
    'gemini-two': 'http://127.0.0.1:18181/google/v1beta/models/gemini-2.5-pro:generateContent',
    'gemini-model-escape': 'http://127.0.0.1:18181/google/v1beta/models/publisher%2Fmodel%20beta:generateContent',
  });
});

test('fixture records executed source separately from imported platform services and comparison limits', () => {
  assert.equal(capture.sourceAudit.length, 1);
  assert.equal(capture.platformBoundaries.length, 11);
  for (const item of capture.platformBoundaries) assert.equal(item.originalSourceExecuted, false);
  assert.ok(capture.limits.some(value => value.includes('inline_data/mime_type')));
  assert.ok(capture.limits.some(value => value.includes('one-shot JSON HTTP')));
  assert.ok(capture.limits.some(value => value.includes('synthetic PDF byte tokens')));
  for (const row of capture.observations) {
    assert.equal(row.platformCalls.filter(call => call.export === 'postJsonRequest').length, 1);
    assert.equal(row.platformCalls.filter(call => call.export === 'release').length, 1);
  }
});
