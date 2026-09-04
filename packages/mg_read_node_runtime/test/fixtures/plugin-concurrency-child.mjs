/** Child-process probes for bounded Runtime concurrency diagnostics. */
import { DesktopRuntime, PluginManager } from "../../dist/index.js";

const [mode, dataRoot, pluginId] = process.argv.slice(2);
if (typeof mode !== "string" || typeof dataRoot !== "string" || typeof pluginId !== "string") {
  throw new Error("Expected mode, dataRoot and pluginId.");
}

const request = (query) => ({ query, cursor: null, pageSize: 20 });
const deadline = () => String(Date.now() + 5_000);

if (mode === "hang-stop") {
  const runtime = new DesktopRuntime({ dataRoot, embedded: true });
  await runtime.start();
  void runtime.invokeEmbedded(
    "source.search.v1",
    { pluginId, ...request("hang") },
    Date.now() + 25,
  );
  await new Promise((resolve) => setImmediate(resolve));
  await runtime.stop();
  process.stdout.write("stopped\n");
} else if (mode === "stress") {
  if (typeof globalThis.gc !== "function") throw new Error("Stress probe requires --expose-gc.");
  const manager = new PluginManager(dataRoot);
  await manager.initialize();
  const waves = 6;
  const callsPerWave = 400;
  let completed = 0;
  let cacheClearFailures = 0;
  const heapSamples = [];
  const unhandled = [];
  const onUnhandled = (reason) => { unhandled.push(reason); };
  process.on("unhandledRejection", onUnhandled);
  for (let wave = 0; wave < waves; wave += 1) {
    const results = await Promise.allSettled(
      Array.from({ length: callsPerWave }, (_, index) =>
        manager.search(
          pluginId,
          request(index % 37 === 0 ? "throw" : "fast"),
          new AbortController().signal,
          deadline(),
        )),
    );
    completed += results.length;
    const clear = await manager.clearPluginCache(pluginId);
    cacheClearFailures += clear.items.filter((item) => item.status !== "cleared").length;
    globalThis.gc();
    await new Promise((resolve) => setImmediate(resolve));
    globalThis.gc();
    heapSamples.push(process.memoryUsage().heapUsed);
  }
  await new Promise((resolve) => setImmediate(resolve));
  process.off("unhandledRejection", onUnhandled);
  await manager.close();
  process.stdout.write(`${JSON.stringify({
    cacheClearFailures,
    callsPerWave,
    completed,
    heapSamples,
    unhandledRejections: unhandled.length,
    waves,
  })}\n`);
} else {
  throw new Error(`Unknown probe mode: ${mode}`);
}
