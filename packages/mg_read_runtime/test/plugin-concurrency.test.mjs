/**
 * Runtime plugin-concurrency diagnostics.
 *
 * Responsibilities:
 * - prove the effective per-plugin scheduling boundary with real plugin calls;
 * - keep cancellation, timeout, hanging work, CPU blocking and stress probes bounded;
 * - exercise only public Runtime/PluginManager entry points without changing production policy.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { PluginInstaller, PluginManager } from "../dist/index.js";

const probeChild = fileURLToPath(
  new URL("./fixtures/plugin-concurrency-child.mjs", import.meta.url),
);
const pluginDelayMs = 80;
const cpuBlockMs = 120;

async function temporaryDirectory(t, prefix) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  t.after(() => rm(root, { force: true, recursive: true }));
  return root;
}

async function createProbeProject(root, pluginId, recorderKey, options = {}) {
  await mkdir(join(root, "dist"), { recursive: true });
  const packageName = `@mgread-plugin/${pluginId.split(".").at(-1)}`;
  const packageJson = {
    name: packageName,
    version: "1.0.0",
    type: "module",
    main: "dist/index.mjs",
    engines: { node: ">=24 <25" },
    mgread: {
      schemaVersion: 1,
      id: pluginId,
      displayName: `Concurrency probe ${pluginId}`,
      pluginApi: 1,
      contentKinds: ["novel"],
    },
  };
  const lock = {
    name: packageName,
    version: packageJson.version,
    lockfileVersion: 3,
    requires: true,
    packages: {
      "": { name: packageName, version: packageJson.version },
    },
  };
  const entry = `
const pluginId = ${JSON.stringify(pluginId)};
const recorderKey = ${JSON.stringify(recorderKey)};
const delayMs = ${pluginDelayMs};
const cpuBlockMs = ${cpuBlockMs};
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const record = (operation, phase, label) => {
  const events = globalThis[recorderKey];
  if (Array.isArray(events)) events.push({ at: performance.now(), label, operation, phase, pluginId });
};
const run = async (operation, label) => {
  record(operation, "start", label);
  if (label.startsWith("hang")) await new Promise(() => {});
  if (label === "throw") throw new Error("probe failure");
  if (label.startsWith("http:")) {
    const response = await context.http.fetch(label.slice(5));
    await response.text();
  }
  if (label === "cpu") {
    const deadline = performance.now() + cpuBlockMs;
    while (performance.now() < deadline) {}
  }
  if (["cancel", "delay", "io", "timeout"].includes(label)) await sleep(delayMs);
  record(operation, "end", label);
};
const summary = (id) => ({
  id,
  title: "Concurrency probe",
  contentKind: "novel",
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: "unknown",
  access: "unknown",
  wordCount: null,
  chapterCount: 0,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: [],
  tags: [],
  attributes: [],
});

let context;
${options.hangOnActivate
    ? "export async function activate() { await new Promise(() => {}); }"
    : "export function activate(nextContext) { context = nextContext; }"}
export async function discover(request) {
  await run("discover", request.target ?? "discover");
  return { kind: "document", document: { components: [] } };
}
export async function search(request) {
  await run("search", request.query);
  return { items: [], nextCursor: null, totalCount: 0 };
}
export async function searchSuggestions() {
  await run("searchSuggestions", "suggestions");
  return { items: [], nextCursor: null };
}
export async function getDetail(request) {
  await run("getDetail", request.id);
  return summary(request.id);
}
export async function getChapters(request) {
  await run("getChapters", request.id);
  return { items: [], totalCount: 0 };
}
export async function getContent(request) {
  await run("getContent", request.chapterId);
  return {
    chapterId: request.chapterId,
    contentKind: "novel",
    title: null,
    updatedAt: null,
    text: "probe",
    pages: [],
    media: null,
  };
}
`;
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify(packageJson, null, 2)}\n`),
    writeFile(join(root, "package-lock.json"), `${JSON.stringify(lock, null, 2)}\n`),
    writeFile(join(root, "dist", "index.mjs"), entry),
  ]);
  return root;
}

async function installProbe(dataRoot, projectRoot, pluginId, recorderKey, options = {}) {
  await createProbeProject(projectRoot, pluginId, recorderKey, options);
  await new PluginInstaller(dataRoot).installProject(projectRoot);
}

function search(manager, pluginId, query, options = {}) {
  return manager.search(
    pluginId,
    { query, cursor: null, pageSize: 20 },
    options.signal ?? new AbortController().signal,
    String(options.deadline ?? Date.now() + 2_000),
  );
}

function discover(manager, pluginId, target, options = {}) {
  return manager.discover(
    pluginId,
    { collectionId: null, cursor: null, pageSize: 20, target },
    options.signal ?? new AbortController().signal,
    String(options.deadline ?? Date.now() + 2_000),
  );
}

async function waitFor(predicate, timeoutMs = 500) {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("Timed out waiting for probe event.");
    await new Promise((resolve) => setImmediate(resolve));
  }
}

async function settleWithin(promise, timeoutMs) {
  const result = await Promise.race([
    promise.then(
      (value) => ({ state: "fulfilled", value }),
      (reason) => ({ reason, state: "rejected" }),
    ),
    new Promise((resolve) => setTimeout(() => resolve({ state: "pending" }), timeoutMs)),
  ]);
  return result;
}

async function runProbeChild(mode, dataRoot, pluginId, options = {}) {
  const startedAt = performance.now();
  const child = spawn(
    process.execPath,
    [...(options.nodeArgs ?? []), probeChild, mode, dataRoot, pluginId],
    { stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const timeoutMs = options.timeoutMs ?? 4_000;
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    child.kill();
  }, timeoutMs);
  const result = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  clearTimeout(timeout);
  return { ...result, elapsedMs: performance.now() - startedAt, stderr, stdout, timedOut };
}

test("same-plugin source capabilities overlap under shared invocation leases", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-same-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.same";
  const recorderKey = `__mgread_probe_${process.pid}_same`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);
  const manager = new PluginManager(dataRoot);
  await manager.initialize();

  const startedAt = performance.now();
  await Promise.all([
    search(manager, pluginId, "delay"),
    discover(manager, pluginId, "after-delay"),
  ]);
  const elapsedMs = performance.now() - startedAt;
  const searchEnd = events.find((event) => event.operation === "search" && event.phase === "end");
  const discoverStart = events.find((event) => event.operation === "discover" && event.phase === "start");
  assert.ok(discoverStart.at < searchEnd.at);
  t.diagnostic(`same-plugin elapsedMs=${elapsedMs.toFixed(1)} order=${events.map((event) => `${event.operation}:${event.phase}`).join(",")}`);
});

test("different plugins overlap when their work yields to the event loop", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-different-");
  const dataRoot = join(root, "runtime-data");
  const pluginA = "org.example.concurrent.a";
  const pluginB = "org.example.concurrent.b";
  const recorderKey = `__mgread_probe_${process.pid}_different`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project-a"), pluginA, recorderKey);
  await installProbe(dataRoot, join(root, "project-b"), pluginB, recorderKey);
  const manager = new PluginManager(dataRoot);
  await manager.initialize();

  const startedAt = performance.now();
  await Promise.all([
    search(manager, pluginA, "io"),
    search(manager, pluginB, "io"),
  ]);
  const elapsedMs = performance.now() - startedAt;
  const starts = events.filter((event) => event.phase === "start");
  const ends = events.filter((event) => event.phase === "end");
  assert.equal(starts.length, 2);
  assert.equal(ends.length, 2);
  assert.ok(Math.max(...starts.map((event) => event.at)) < Math.min(...ends.map((event) => event.at)));
  t.diagnostic(`different-plugin elapsedMs=${elapsedMs.toFixed(1)} startDeltaMs=${Math.abs(starts[0].at - starts[1].at).toFixed(1)}`);
});

test("different plugins issue overlapping ctx.http.fetch requests on loopback", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-http-");
  const dataRoot = join(root, "runtime-data");
  const pluginA = "org.example.concurrent.httpa";
  const pluginB = "org.example.concurrent.httpb";
  const recorderKey = `__mgread_probe_${process.pid}_http`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project-a"), pluginA, recorderKey);
  await installProbe(dataRoot, join(root, "project-b"), pluginB, recorderKey);
  const manager = new PluginManager(dataRoot);
  await manager.initialize();

  const pendingResponses = [];
  let requestCount = 0;
  let overlapped = false;
  let fallback;
  const server = createServer((_request, response) => {
    requestCount += 1;
    pendingResponses.push(response);
    if (pendingResponses.length === 1) {
      fallback = setTimeout(() => pendingResponses.splice(0).forEach((item) => item.end("fallback")), 300);
    }
    if (pendingResponses.length === 2) {
      overlapped = true;
      clearTimeout(fallback);
      pendingResponses.splice(0).forEach((item) => item.end("overlap"));
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0 }, resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, "object");
  const url = `http://127.0.0.1:${address.port}/probe`;

  const startedAt = performance.now();
  await Promise.all([
    search(manager, pluginA, `http:${url}`),
    search(manager, pluginB, `http:${url}`),
  ]);
  const elapsedMs = performance.now() - startedAt;
  assert.equal(requestCount, 2);
  assert.equal(overlapped, true);
  t.diagnostic(`loopback-http overlapped=${overlapped} elapsedMs=${elapsedMs.toFixed(1)} requests=${requestCount}`);
});

test("success, rejection, timeout and cancellation leave same-plugin capacity usable", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-release-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.release";
  const recorderKey = `__mgread_probe_${process.pid}_release`;
  globalThis[recorderKey] = [];
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);
  const manager = new PluginManager(dataRoot);
  await manager.initialize();

  const cases = [
    { label: "delay", expectedCode: null },
    { label: "throw", expectedCode: "plugin_execution_failed" },
    { label: "timeout", expectedCode: "timeout" },
    { label: "cancel", expectedCode: "cancelled" },
  ];
  for (const current of cases) {
    const controller = new AbortController();
    const startedAt = performance.now();
    const first = search(manager, pluginId, current.label, {
      deadline: current.label === "timeout" ? Date.now() + 10 : Date.now() + 2_000,
      signal: controller.signal,
    });
    const second = discover(manager, pluginId, `after-${current.label}`);
    if (current.label === "cancel") setTimeout(() => controller.abort(), 10);
    if (current.expectedCode === null) {
      await first;
    } else {
      await assert.rejects(first, (error) => error?.code === current.expectedCode);
    }
    const firstElapsedMs = performance.now() - startedAt;
    const followUp = await settleWithin(second, 500);
    assert.equal(followUp.state, "fulfilled", `follow-up after ${current.label} did not complete`);
    if (current.label === "timeout" || current.label === "cancel") {
      assert.ok(firstElapsedMs < pluginDelayMs - 20);
    }
    t.diagnostic(`${current.label} firstElapsedMs=${firstElapsedMs.toFixed(1)} followUp=${followUp.state}`);
  }
  await new Promise((resolve) => setTimeout(resolve, pluginDelayMs + 20));
});

test("a never-settling call times out without blocking later same-plugin capabilities", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-hang-");
  const dataRoot = join(root, "runtime-data");
  const pluginA = "org.example.concurrent.hang";
  const pluginB = "org.example.concurrent.escape";
  const recorderKey = `__mgread_probe_${process.pid}_hang`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project-hang"), pluginA, recorderKey);
  await installProbe(dataRoot, join(root, "project-escape"), pluginB, recorderKey);
  const manager = new PluginManager(dataRoot, { cacheClearTimeoutMs: 80 });
  await manager.initialize();

  const hanging = search(manager, pluginA, "hang", { deadline: Date.now() + 25 });
  await waitFor(() => events.some((event) => event.pluginId === pluginA && event.label === "hang"));
  const followUpCount = 64;
  const followUps = Array.from({ length: followUpCount }, (_, index) =>
    discover(manager, pluginA, `follow-up-${index}`));
  const cacheClear = manager.clearPluginCache(pluginA);

  const unrelated = await settleWithin(search(manager, pluginB, "fast"), 300);
  assert.equal(unrelated.state, "fulfilled");
  const [hangingState, followUpStates, cacheState] = await Promise.all([
    settleWithin(hanging, 150),
    Promise.all(followUps.map((operation) => settleWithin(operation, 500))),
    settleWithin(cacheClear, 250),
  ]);
  assert.equal(hangingState.state, "rejected");
  assert.equal(hangingState.reason?.code, "timeout");
  assert.equal(followUpStates.filter((state) => state.state === "fulfilled").length, followUpCount);
  assert.equal(cacheState.state, "fulfilled");
  assert.equal(cacheState.value.items[0].status, "failed");
  assert.equal(events.filter((event) => event.pluginId === pluginA && event.label.startsWith("follow-up-") && event.phase === "end").length, followUpCount);
  t.diagnostic(`hang=${hangingState.reason?.code} followUps=${followUpStates.length}xfulfilled cacheClear=${cacheState.value.items[0].status} otherPlugin=${unrelated.state}`);
});

test("Runtime-owned resource fetch observes cancellation without occupying plugin capability", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-resource-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.resource";
  const recorderKey = `__mgread_probe_${process.pid}_resource`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);
  let fetchAborted = false;
  const manager = new PluginManager(dataRoot, { http: { fetch(_input, init) {
    return new Promise((_resolve, reject) => {
      const abort = () => {
        fetchAborted = true;
        reject(new DOMException("The operation was aborted", "AbortError"));
      };
      if (init?.signal?.aborted) abort();
      else init?.signal?.addEventListener("abort", abort, { once: true });
    });
  } } });
  await manager.initialize();
  const url = manager.createResourceUrl(pluginId, { kind: "image", url: "https://resource.example/hang", headers: {} });
  const token = new URL(url).pathname.split("/").at(-1);
  const controller = new AbortController();

  const startedAt = performance.now();
  const resource = manager.openSourceResource(token, {}, controller.signal);
  setTimeout(() => controller.abort(), 10);
  await assert.rejects(resource, (error) => error?.name === "AbortError");
  const elapsedMs = performance.now() - startedAt;
  const followUp = await settleWithin(search(manager, pluginId, "fast"), 300);
  assert.equal(followUp.state, "fulfilled");
  assert.equal(fetchAborted, true);
  assert.ok(elapsedMs < 100);
  t.diagnostic(`resourceCancelMs=${elapsedMs.toFixed(1)} followUp=${followUp.state}`);
});

test("cache cleanup is exclusive and later invocations resume after it", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-cache-exclusive-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.cacheexclusive";
  const recorderKey = `__mgread_probe_${process.pid}_cache_exclusive`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);
  const manager = new PluginManager(dataRoot, { cacheClearTimeoutMs: 500 });
  await manager.initialize();

  const active = search(manager, pluginId, "delay");
  await waitFor(() => events.some((event) => event.label === "delay" && event.phase === "start"));
  const clear = manager.clearPluginCache(pluginId);
  const after = discover(manager, pluginId, "after-clear");
  const [clearResult] = await Promise.all([clear, active, after]);
  assert.equal(clearResult.items[0].status, "cleared");
  const activeEnd = events.find((event) => event.label === "delay" && event.phase === "end");
  const afterStart = events.find((event) => event.label === "after-clear" && event.phase === "start");
  assert.ok(activeEnd.at <= afterStart.at);
  t.diagnostic(`cacheClear=${clearResult.items[0].status} invocationResumedAfterActive=${activeEnd.at <= afterStart.at}`);
});

test("per-plugin capacity rejects overflow and removes cancelled waiters", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-capacity-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.capacity";
  const recorderKey = `__mgread_probe_${process.pid}_capacity`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);
  const manager = new PluginManager(dataRoot, {
    maxActiveInvocationsPerPlugin: 2,
    maxQueuedOperationsPerPlugin: 3,
  });
  await manager.initialize();

  const active = [
    search(manager, pluginId, "hang-a", { deadline: Date.now() + 50 }),
    search(manager, pluginId, "hang-b", { deadline: Date.now() + 50 }),
  ];
  await waitFor(() => events.filter((event) => event.label.startsWith("hang-") && event.phase === "start").length === 2);
  const queuedController = new AbortController();
  const queued = Array.from({ length: 3 }, (_, index) =>
    discover(manager, pluginId, `queued-${index}`, {
      deadline: Date.now() + 500,
      signal: queuedController.signal,
    }));
  await assert.rejects(
    discover(manager, pluginId, "overflow", { deadline: Date.now() + 500 }),
    (error) => error?.code === "overloaded",
  );
  queuedController.abort();
  const cancelled = await Promise.allSettled(queued);
  assert.equal(cancelled.filter((result) => result.status === "rejected" && result.reason?.code === "cancelled").length, 3);
  await Promise.all(active.map((operation) =>
    assert.rejects(operation, (error) => error?.code === "timeout")));
  await assert.rejects(
    discover(manager, pluginId, "replacement", { deadline: Date.now() + 35 }),
    (error) => error?.code === "timeout",
  );
  t.diagnostic("capacity active=2 queued=3 overflow=overloaded cancelledWaitersRemoved=true");
});

test("an async activate hook that never settles is quarantined within the activation deadline", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-activation-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.activation";
  const recorderKey = `__mgread_probe_${process.pid}_activation`;
  await installProbe(
    dataRoot,
    join(root, "project"),
    pluginId,
    recorderKey,
    { hangOnActivate: true },
  );
  const manager = new PluginManager(dataRoot, { pluginActivationTimeoutMs: 40 });

  const startedAt = performance.now();
  await manager.initialize();
  const elapsedMs = performance.now() - startedAt;
  const snapshot = (await manager.listInstalled()).find((item) => item.id === pluginId);
  assert.equal(snapshot?.status, "quarantined");
  assert.ok(elapsedMs >= 30 && elapsedMs < 500);
  t.diagnostic(`activation status=${snapshot?.status} elapsedMs=${elapsedMs.toFixed(1)}`);
});

test("CPU-bound plugin code blocks timers and unrelated plugins in the shared Node VM", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-cpu-");
  const dataRoot = join(root, "runtime-data");
  const pluginA = "org.example.concurrent.cpu";
  const pluginB = "org.example.concurrent.cpuescape";
  const recorderKey = `__mgread_probe_${process.pid}_cpu`;
  const events = [];
  globalThis[recorderKey] = events;
  t.after(() => { delete globalThis[recorderKey]; });
  await installProbe(dataRoot, join(root, "project-cpu"), pluginA, recorderKey);
  await installProbe(dataRoot, join(root, "project-other"), pluginB, recorderKey);
  const manager = new PluginManager(dataRoot);
  await manager.initialize();

  const startedAt = performance.now();
  let timerDelayMs = 0;
  const timer = new Promise((resolve) => setTimeout(() => {
    timerDelayMs = performance.now() - startedAt;
    resolve();
  }, 5));
  await Promise.all([
    search(manager, pluginA, "cpu"),
    search(manager, pluginB, "fast"),
    timer,
  ]);
  const cpuEnd = events.find((event) => event.pluginId === pluginA && event.phase === "end");
  const otherStart = events.find((event) => event.pluginId === pluginB && event.phase === "start");
  assert.ok(timerDelayMs >= cpuBlockMs - 20);
  assert.ok(cpuEnd.at <= otherStart.at);
  t.diagnostic(`cpuBlockMs=${cpuBlockMs} observedTimerDelayMs=${timerDelayMs.toFixed(1)} otherPluginStartedAfterCpu=${cpuEnd.at <= otherStart.at}`);
});

test("high concurrency drains without deadlock, unhandled rejection or sustained post-GC heap growth", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-stress-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.stress";
  const recorderKey = `__mgread_probe_${process.pid}_stress`;
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);

  const result = await runProbeChild("stress", dataRoot, pluginId, {
    nodeArgs: ["--expose-gc"],
    timeoutMs: 10_000,
  });
  assert.equal(result.timedOut, false, result.stderr);
  assert.equal(result.code, 0, result.stderr);
  const report = JSON.parse(result.stdout.trim());
  assert.equal(report.completed, report.waves * report.callsPerWave);
  assert.equal(report.unhandledRejections, 0);
  assert.equal(report.cacheClearFailures, 0);
  assert.ok(report.heapSamples.at(-1) - report.heapSamples[0] < 8 * 1024 * 1024);
  t.diagnostic(`stress elapsedMs=${result.elapsedMs.toFixed(1)} calls=${report.completed} heapSamples=${report.heapSamples.join(",")}`);
});

test("Runtime stop and process exit complete while an installed plugin Promise remains pending", async (t) => {
  const root = await temporaryDirectory(t, "mgread-concurrency-exit-");
  const dataRoot = join(root, "runtime-data");
  const pluginId = "org.example.concurrent.exit";
  const recorderKey = `__mgread_probe_${process.pid}_exit`;
  await installProbe(dataRoot, join(root, "project"), pluginId, recorderKey);

  const result = await runProbeChild("hang-stop", dataRoot, pluginId, { timeoutMs: 4_000 });
  assert.equal(result.timedOut, false, result.stderr);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /stopped/u);
  t.diagnostic(`hang-stop childExitMs=${result.elapsedMs.toFixed(1)}`);
});
