import { channel } from "node:diagnostics_channel";
import { performance } from "node:perf_hooks";
import { isMainThread } from "node:worker_threads";
import { threadId } from "node:worker_threads";
const redactionPerformance = channel("openclaw.redaction");
export function startRedactionMeasurement(operation                       ) {
  if (!redactionPerformance.hasSubscribers) {
    return undefined;
  }
  const startedAt = performance.now();
  const cpu = process.threadCpuUsage();
  return (outcome                , inputChars         , patternCount         ) => {
    const elapsedMs = performance.now() - startedAt;
    const used = process.threadCpuUsage(cpu);
    redactionPerformance.publish({
      operation,
      outcome,
      pid: process.pid,
      threadId,
      isMainThread,
      elapsedMs,
      threadCpuMs: (used.user + used.system) / 1_000,
      ...(inputChars === undefined ? {} : { inputChars }),
      ...(patternCount === undefined ? {} : { patternCount }),
    });
  };
}
export { redactionPerformance };