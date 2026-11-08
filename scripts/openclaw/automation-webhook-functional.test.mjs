// Ordinary successful webhook lifecycle only. Failure handling is source review.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import { captureAutomationWebhook } from './capture-automation-webhook.mjs';

const source = process.env.OPENCLAW_AUTOMATION_WEBHOOK_SOURCE ?? '/tmp/openclaw-488631c';
const capture = await captureAutomationWebhook(source);
const rows = new Map(capture.observations.map(row => [row.id, row]));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

test('primary webhook awaits held receiver ACK before authored run completion', () => {
  assert.equal(rows.size, 4);
  for (const id of ['unicode-attributed-held-ack', 'unicode-optional-fields-omitted-held-ack']) {
    const row = rows.get(id);
    assert.deepEqual(row.pending, { receiverPending: true, runSettled: false, scopeHasPendingWork: true,
      activeCoreCount: 1, postCount: 1,
      trace: ['executor-completed', 'webhook-adapter-entered', 'receiver-request'] });
    assert.deepEqual(row.trace, ['executor-completed', 'webhook-adapter-entered', 'receiver-request',
      'receiver-ack-204', 'webhook-adapter-settled', 'run-completion-authored']);
    assert.equal(row.requests.length, 1);
    const request = row.requests[0];
    assert.equal(request.url, 'https://webhook.example.com/automation');
    assert.equal(request.method, 'POST');
    assert.deepEqual(request.headers, { 'content-type': 'application/json' });
    assert.equal(request.redirect, 'manual');
    assert.equal(request.signalSupplied, true);
    assert.deepEqual(row.transportOutcomes, [{ status: 'delivered' }]);
    assert.equal(row.result.status, 'ok');
    assert.equal(row.result.completionStatus, 'succeeded');
    assert.equal(row.result.deliveryState.status, 'delivered');
    assert.equal(row.result.delivered, true);
    assert.equal(row.result.deliveryAttempted, true);
    assert.equal(row.result.summary, row.summary);
    assert.deepEqual(row.result.delivery, { intended: { to: request.url, source: 'explicit' },
      delivered: true, resolved: { to: request.url, source: 'explicit', ok: true } });
    assert.equal(Object.hasOwn(row.result, 'deliveryError'), false);
    assert.equal(Object.hasOwn(row.result, 'deliverySuppressionReason'), false);
  }
});

test('original event constructor sends finished-event JSON with exact Unicode and attribution', () => {
  for (const id of ['unicode-attributed-held-ack', 'unicode-optional-fields-omitted-held-ack']) {
    const row = rows.get(id); const event = JSON.parse(row.requests[0].body);
    assert.equal(row.requests[0].body, JSON.stringify(event));
    assert.deepEqual(event, { jobId: row.job.id, action: 'finished', job: row.job,
      runAtMs: 1793181600000, durationMs: 123, status: 'ok', summary: row.summary,
      delivered: true, deliveryStatus: 'delivered', delivery: row.result.delivery,
      ...(row.attributed ? { sessionId: 'fixture-session',
        sessionKey: 'agent:fixture-agent:cron:fixture-webhook-job', model: 'fixture-model',
        provider: 'fixture-provider', usage: { input_tokens: 17, output_tokens: 9, total_tokens: 26 } } : {}),
    });
    for (const optional of ['error', 'diagnostics']) assert.equal(Object.hasOwn(event, optional), false);
    if (!row.attributed) for (const optional of ['model', 'provider', 'usage', 'sessionId', 'sessionKey']) {
      assert.equal(Object.hasOwn(event, optional), false);
      assert.equal(Object.hasOwn(row.result, optional), false);
    }
  }
});

test('successful whitespace and empty summaries intentionally suppress primary POST', () => {
  for (const id of ['whitespace-summary-suppressed', 'empty-summary-suppressed']) {
    const row = rows.get(id);
    assert.equal(row.pending, null);
    assert.deepEqual(row.requests, []);
    assert.deepEqual(row.transportOutcomes, []);
    assert.deepEqual(row.trace, ['executor-completed', 'run-completion-authored']);
    assert.equal(row.result.status, 'ok');
    assert.equal(row.result.summary, row.summary);
    assert.equal(row.result.completionStatus, 'succeeded');
    assert.equal(row.result.deliveryAttempted, false);
    assert.equal(row.result.delivered, false);
    assert.equal(row.result.deliverySuppressionReason, 'empty');
    assert.deepEqual(row.result.deliveryState, { status: 'not-delivered', delivered: false,
      deliverySuppressionReason: 'empty', failureNotification: { status: 'not-requested' } });
    assert.deepEqual(row.result.delivery, { intended: { to: row.job.delivery.to, source: 'explicit' },
      delivered: false, resolved: { to: row.job.delivery.to, source: 'explicit', ok: false } });
  }
});

test('ordinary completion drains original async tracking and releases capture-owned resources', () => {
  for (const row of rows.values()) {
    assert.equal(row.runSettled, true);
    assert.equal(row.scopeHasPendingWork, false);
    assert.equal(row.activeCoreCount, 0);
    assert.deepEqual(row.warnings, []);
    assert.deepEqual(row.executorCalls, [{ jobId: row.job.id, message: row.job.payload.message,
      abortSignalSupplied: true, admissionSource: 'operator-schedule', occurrenceSupplied: true }]);
    assert.equal(row.suppliedExecutorResult.status, 'ok');
    for (const delivery of ['delivery', 'deliveryState', 'delivered', 'deliveryAttempted']) {
      assert.equal(Object.hasOwn(row.suppliedExecutorResult, delivery), false);
    }
  }
});

test('whole-source package runtime provenance reproduces without expanding whole-reference gates', () => {
  assert.equal(capture.referencePin, '488631c18fae7cc541ba8fc8beff6cbb0438787b');
  const required = ['src/cron/service/timer-job-runner.ts', 'src/cron/service/timer-execution.ts',
    'src/cron/service/timer-job-runner.interruption.ts', 'src/cron/completion-status.ts',
    'src/gateway/server-cron-notifications.ts', 'src/cron/isolated-agent/delivery-dispatch-policy.ts',
    'src/infra/net/fetch-guard.ts', 'src/infra/net/ssrf.ts', 'src/secrets/runtime-degraded-state.ts',
    'src/shared/async-work-scope.ts', 'src/cron/service/active-run-cancellation.ts'];
  for (const path of required) assert.ok(capture.sourceRecords.some(row => row.path === path && row.executed), path);
  for (const row of capture.sourceRecords) {
    const bytes = readFileSync(join(source, row.path)); assert.equal(hash(bytes), row.sha256);
    if (row.executed) {
      assert.equal(row.wholeModule, true);
      assert.equal(hash(stripTypeScriptTypes(bytes.toString(), { mode: 'transform', sourceMap: false })), row.executableSha256);
    }
  }
  for (const row of capture.importBindings) if (row.generatedCode) assert.equal(hash(row.generatedCode), row.generatedSha256);
  assert.deepEqual(capture.packages.map(pkg => [pkg.name, pkg.version]), [['ipaddr.js', '2.5.0'], ['zod', '4.6.7']]);
  for (const pkg of capture.packages) {
    assert.deepEqual(pkg.before, pkg.after); assert.equal(pkg.originalInstalledTreeUnchanged, true);
    assert.ok(pkg.loadedFiles.length > 0);
    for (const row of pkg.before) assert.equal(hash(readFileSync(join(pkg.root, row.path))), row.sha256);
  }
  assert.deepEqual(capture.sourceTree.before, capture.sourceTree.after);
  assert.equal(capture.runtime.version, '24.22.1');
  assert.equal(hash(readFileSync(capture.runtime.executable)), capture.runtime.sha256);
  assert.equal(hash(readFileSync(new URL('./capture-automation-webhook.mjs', import.meta.url))), capture.exporter.sha256);
  assert.equal(hash(capture.host.generatedCode), capture.host.sha256);
  assert.deepEqual(capture.deferredCalls, []);
  for (const name of ['wholeRunnerExecuted', 'wholeCoreExecuted', 'originalEventConstructorExecuted',
    'wholePrimaryTransportExecuted', 'wholeFetchGuardExecuted', 'originalOrdinaryGuardsRetained',
    'ordinaryTimersExecutedAndReleased', 'asyncWorkTrackingExecuted']) assert.equal(capture.boundaries[name], true);
  for (const name of ['dnsExecuted', 'socketExecuted', 'dispatcherExecuted', 'storageExecuted',
    'runtimeAssemblyExecuted', 'schedulerExecuted', 'runQueueFinalizationExecuted', 'modelFactoryExecuted',
    'scriptsExecuted', 'triggersExecuted', 'realProviderExecuted', 'fullAutomationParity']) {
    assert.equal(capture.boundaries[name], false);
  }
  assert.equal(capture.boundaries.sourceOnlyReview.failureTestsExecuted, false);
  assert.deepEqual(capture, JSON.parse(readFileSync(new URL('../../apps/synapsis_agent/test/fixtures/openclaw/488631c/automation-webhook.json', import.meta.url))));
});
