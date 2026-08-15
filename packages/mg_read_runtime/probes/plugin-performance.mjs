// @ts-check

import { mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { PluginInstaller, PluginManager } from "../dist/index.js";
import { runtimeDiagnosticValue } from "../dist/diagnostics/contracts.js";
import { runtimeDiagnosticEvents } from "../dist/diagnostics/registry.js";
import { RuntimeDiagnosticsService } from "../dist/diagnostics/service.js";

const iterations = 1_000;
const warmupIterations = 100;
const fixtureRoot = fileURLToPath(
  new URL("../test/fixtures/standard-plugin/", import.meta.url),
);

const results = [];
for (const diagnostics of ["disabled", "metadataOnly"]) {
  const dataRoot = await mkdtemp(join(tmpdir(), `mgread-plugin-perf-${diagnostics}-`));
  let diagnosticService;
  try {
    await new PluginInstaller(dataRoot).installProject(fixtureRoot);
    const manager = new PluginManager(dataRoot);
    await manager.initialize();
    if (diagnostics === "metadataOnly") {
      diagnosticService = await RuntimeDiagnosticsService.open({ dataRoot });
    }
    const signal = new AbortController().signal;
    for (let index = 0; index < warmupIterations; index += 1) {
      await measuredSearch(
        diagnosticService,
        manager,
        "org.mgread.runtime.fixture",
        `warmup-${index}`,
        signal,
      );
    }
    await diagnosticService?.manager.flush();

    globalThis.gc?.();
    const diskBefore = await directoryBytes(dataRoot);
    const heapBefore = process.memoryUsage().heapUsed;
    const writerBefore = diagnosticService?.writerStatistics;
    let peakHeapBytes = heapBefore;
    const samples = [];
    const totalStartedAt = performance.now();
    for (let index = 0; index < iterations; index += 1) {
      const startedAt = performance.now();
      await measuredSearch(
        diagnosticService,
        manager,
        "org.mgread.runtime.fixture",
        `query-${index}`,
        signal,
      );
      samples.push(performance.now() - startedAt);
      peakHeapBytes = Math.max(peakHeapBytes, process.memoryUsage().heapUsed);
    }
    await diagnosticService?.manager.flush();
    const totalMs = performance.now() - totalStartedAt;
    globalThis.gc?.();
    const heapAfter = process.memoryUsage().heapUsed;
    const diskAfter = await directoryBytes(dataRoot);
    const writerAfter = diagnosticService?.writerStatistics;
    samples.sort((left, right) => left - right);
    results.push({
      diagnostics,
      diskGrowthBytes: diskAfter - diskBefore,
      dropCount:
        writerAfter === undefined
          ? 0
          : writerAfter.droppedEvents - (writerBefore?.droppedEvents ?? 0),
      eventCount:
        writerAfter === undefined
          ? 0
          : writerAfter.acceptedEvents - (writerBefore?.acceptedEvents ?? 0),
      heapDeltaBytes: heapAfter - heapBefore,
      iterations,
      p50Ms: percentile(samples, 0.5),
      p95Ms: percentile(samples, 0.95),
      p99Ms: percentile(samples, 0.99),
      peakHeapBytes,
      queueHighWater: writerAfter?.queueHighWater ?? 0,
      throughputPerSecond: (iterations * 1_000) / totalMs,
      totalMs,
    });
  } finally {
    await diagnosticService?.close();
    await rm(dataRoot, { force: true, recursive: true });
  }
}

process.stdout.write(`${JSON.stringify({ results }, null, 2)}\n`);

async function measuredSearch(service, manager, pluginId, keyword, signal) {
  const span = service?.manager.startSpan({
    attributes: () => runtimeDiagnosticValue.object({
      operation: runtimeDiagnosticValue.string("search"),
    }),
    definition: runtimeDiagnosticEvents.pluginInvoke,
  });
  try {
    const result = await manager.search(
      pluginId,
      { query: keyword, cursor: null, pageSize: 20 },
      signal,
      String(Date.now() + 60_000),
    );
    span?.end("success", {
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string("search"),
        resultCount: runtimeDiagnosticValue.int64(BigInt(result.items.length)),
      }),
    });
    return result;
  } catch (error) {
    span?.end("error", {
      attributes: () => runtimeDiagnosticValue.object({
        errorCode: runtimeDiagnosticValue.string("plugin_search_failed"),
        operation: runtimeDiagnosticValue.string("search"),
      }),
      severity: "error",
    });
    throw error;
  }
}

/** @param {number[]} values @param {number} quantile */
function percentile(values, quantile) {
  const index = Math.min(
    values.length - 1,
    Math.max(0, Math.ceil(values.length * quantile) - 1),
  );
  return Number(values[index].toFixed(6));
}

/** @param {string} root */
async function directoryBytes(root) {
  let total = 0;
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      total += await directoryBytes(path);
    } else if (entry.isFile()) {
      total += (await stat(path)).size;
    }
  }
  return total;
}
