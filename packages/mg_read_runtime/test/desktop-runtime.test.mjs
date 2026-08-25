import assert from "node:assert/strict";
import { access, cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  DesktopRuntime,
  createPluginArchive,
  PluginInstaller,
  protocolVersion,
  runtimeVersion,
} from "../dist/index.js";

// The checked-in fixture is the cross-language compatibility authority. Tests
// derive its limits and endpoints instead of duplicating protocol constants.
const desktopFixture = JSON.parse(
  await readFile(
    new URL("../protocol/fixtures/standard-node-plugin-v1.json", import.meta.url),
    "utf8",
  ),
);
const fixtureRoot = fileURLToPath(
  new URL("./fixtures/standard-plugin/", import.meta.url),
);

async function createRuntime(t, { installFixture = false, openDirectory } = {}) {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-node-test-"));
  if (installFixture) {
    const installer = new PluginInstaller(dataRoot);
    await installer.installProject(fixtureRoot);
  }
  const runtime = new DesktopRuntime({ dataRoot, ...(openDirectory === undefined ? {} : { openDirectory }) });
  t.after(async () => {
    await runtime.stop();
    await rm(dataRoot, { force: true, recursive: true });
  });
  return runtime;
}

/** Builds a fresh, deadline-bounded client-direction request for one test. */
function makeRequest(ready, id, method, overrides = {}) {
  return {
    v: protocolVersion,
    type: "request",
    bootId: ready.bootId,
    id,
    method,
    traceId: `trace:${id}`,
    deadlineUnixMs: String(Date.now() + 5_000),
    params: {},
    ...overrides,
  };
}

/** Opens only the Runtime's loopback RPC endpoint after a Node ready record. */
async function openRuntimeSocket(ready) {
  const socket = new WebSocket(`ws://${ready.host}:${ready.port}/v1/rpc`);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  return socket;
}

/** Sends one request and resolves with its next correlated WebSocket message. */
function sendRequest(socket, request) {
  return new Promise((resolve, reject) => {
    const onMessage = (event) => {
      cleanup();
      try {
        resolve(JSON.parse(String(event.data)));
      } catch (error) {
        reject(error);
      }
    };
    const onError = (event) => {
      cleanup();
      reject(event.error ?? new Error("Runtime WebSocket failed."));
    };
    const cleanup = () => {
      socket.removeEventListener("message", onMessage);
      socket.removeEventListener("error", onError);
    };

    socket.addEventListener("message", onMessage);
    socket.addEventListener("error", onError);
    socket.send(JSON.stringify(request));
  });
}

/**
 * Small test-only request multiplexer used to prove the Core does not impose a
 * request-response lock on a single WebSocket connection.
 */
function createMultiplexedClient(socket) {
  const pending = new Map();
  const onMessage = (event) => {
    try {
      const response = JSON.parse(String(event.data));
      const request = pending.get(response.id);
      if (request === undefined) {
        return;
      }
      pending.delete(response.id);
      request.resolve(response);
    } catch (error) {
      for (const request of pending.values()) {
        request.reject(error);
      }
      pending.clear();
    }
  };
  const onError = (event) => {
    const error = event.error ?? new Error("Runtime WebSocket failed.");
    for (const request of pending.values()) {
      request.reject(error);
    }
    pending.clear();
  };
  socket.addEventListener("message", onMessage);
  socket.addEventListener("error", onError);

  return {
    close() {
      socket.removeEventListener("message", onMessage);
      socket.removeEventListener("error", onError);
    },
    request(request) {
      return new Promise((resolve, reject) => {
        pending.set(request.id, { reject, resolve });
        socket.send(JSON.stringify(request));
      });
    },
  };
}

test("desktop Runtime binds only loopback HTTP health gates", async (t) => {
  const runtime = await createRuntime(t);
  const [ready, duplicateStart] = await Promise.all([runtime.start(), runtime.start()]);
  t.after(() => runtime.stop());

  assert.strictEqual(ready, duplicateStart);
  assert.equal(ready.host, desktopFixture.host);
  assert.equal(ready.protocolVersion, desktopFixture.protocolVersion);
  assert.equal(ready.runtimeVersion, desktopFixture.runtimeVersion);
  assert.ok(ready.port > 0);

  const live = await fetch(
    `http://${ready.host}:${ready.port}${desktopFixture.http.livePath}`,
  );
  assert.equal(live.status, 200);
  assert.deepEqual(await live.json(), {
    bootId: ready.bootId,
    nodeVersion: process.versions.node,
    protocolVersion,
    runtimeVersion,
    status: "live",
  });

  const health = await fetch(
    `http://${ready.host}:${ready.port}${desktopFixture.http.readyPath}`,
  );
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), {
    bootId: ready.bootId,
    nodeVersion: process.versions.node,
    protocolVersion,
    runtimeVersion,
    status: "ready",
  });
});

test("desktop Runtime uses distinct OS-assigned loopback ports without fallback selection", async (t) => {
  const first = await createRuntime(t);
  const second = await createRuntime(t);
  const [firstReady, secondReady] = await Promise.all([
    first.start(),
    second.start(),
  ]);

  assert.equal(firstReady.host, "127.0.0.1");
  assert.equal(secondReady.host, "127.0.0.1");
  assert.ok(firstReady.port > 0);
  assert.ok(secondReady.port > 0);
  assert.notEqual(firstReady.port, secondReady.port);
});

test("desktop Runtime completes hello, ping and stable protocol errors over WebSocket", async (t) => {
  const runtime = await createRuntime(t);
  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(async () => {
    socket.close();
    await runtime.stop();
  });

  const hello = await sendRequest(socket, makeRequest(ready, "c:hello", "runtime.hello"));
  assert.equal(hello.type, "response");
  assert.equal(hello.id, "c:hello");
  assert.equal(hello.bootId, ready.bootId);
  assert.equal(hello.result.protocolVersion, protocolVersion);
  assert.equal(
    hello.result.maxInlineBytes,
    desktopFixture.webSocket.maxControlFrameBytes,
  );
  assert.equal(
    hello.result.maxInFlightRequests,
    desktopFixture.webSocket.maxInFlightRequests,
  );
  assert.equal(
    hello.result.maxOutboundQueueBytes,
    desktopFixture.webSocket.maxOutboundQueueBytes,
  );
  assert.equal(
    hello.result.supportsCancellation,
    desktopFixture.webSocket.supportsCancellation,
  );
  assert.deepEqual(hello.result.capabilities, desktopFixture.webSocket.runtimeMethods.slice(1));

  const ping = await sendRequest(socket, makeRequest(ready, "c:ping", "runtime.ping"));
  assert.deepEqual(ping, {
    v: protocolVersion,
    type: "response",
    bootId: ready.bootId,
    id: "c:ping",
    traceId: "trace:c:ping",
    result: {
      bootId: ready.bootId,
      nodeVersion: process.versions.node,
      ok: true,
      runtimeVersion,
    },
  });

  const status = await sendRequest(
    socket,
    makeRequest(ready, "c:status", "runtime.status.v1"),
  );
  assert.equal(status.type, "response");
  assert.equal(status.id, "c:status");
  assert.equal(status.result.bootId, ready.bootId);
  assert.equal(status.result.nodeVersion, process.versions.node);
  assert.equal(status.result.runtimeVersion, runtimeVersion);
  assert.equal(status.result.ok, true);
  assert.equal(typeof status.result.uptimeMs, "number");
  assert.ok(status.result.uptimeMs >= 0);
  for (const key of ["rss", "heapTotal", "heapUsed", "external", "arrayBuffers"]) {
    assert.equal(typeof status.result.memory[key], "number");
    assert.ok(status.result.memory[key] >= 0);
  }
  assert.ok(Array.isArray(status.result.plugins));

  const unsupported = await sendRequest(
    socket,
    makeRequest(ready, "c:unknown", "plugin.list"),
  );
  assert.equal(unsupported.type, "error");
  assert.equal(unsupported.error.code, "method_not_found");
  assert.equal(unsupported.id, "c:unknown");

  const incompatible = await sendRequest(
    socket,
    makeRequest(ready, "c:version", "runtime.ping", { v: "2.0" }),
  );
  assert.equal(incompatible.type, "error");
  assert.equal(incompatible.error.code, "version_incompatible");

  const shutdownWithoutIdempotencyKey = await sendRequest(
    socket,
    makeRequest(ready, "c:shutdown", "runtime.shutdown"),
  );
  assert.equal(shutdownWithoutIdempotencyKey.type, "error");
  assert.equal(shutdownWithoutIdempotencyKey.error.code, "invalid_request");
});

test("desktop Runtime loads and searches an installed standard Node plugin", async (t) => {
  const runtime = await createRuntime(t, { installFixture: true });
  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(async () => {
    socket.close();
    await runtime.stop();
  });

  const hello = await sendRequest(socket, makeRequest(ready, "c:plugin-hello", "runtime.hello"));
  assert.equal(hello.type, "response");
  assert.deepEqual(
    hello.result.capabilities,
    desktopFixture.webSocket.runtimeMethods.slice(1),
  );

  const plugins = await sendRequest(
    socket,
    makeRequest(ready, "c:plugins", "plugins.list.v1"),
  );
  assert.equal(plugins.type, "response");
  assert.equal(plugins.result.length, 1);
  assert.equal(plugins.result[0].id, desktopFixture.plugin.id);
  assert.equal(plugins.result[0].displayName, desktopFixture.plugin.displayName);
  assert.equal(plugins.result[0].activeVersion, desktopFixture.plugin.version);

  const response = await sendRequest(
    socket,
    makeRequest(
      ready,
      "c:plugin-search",
      "source.search.v1",
      {
        params: {
          query: desktopFixture.plugin.searchKeyword,
          cursor: null,
          pageSize: 20,
          pluginId: desktopFixture.plugin.id,
        },
      },
    ),
  );
  assert.equal(response.type, "response");
  assert.equal(response.result.pluginId, desktopFixture.plugin.id);
  assert.equal(response.result.items[0].title, desktopFixture.plugin.searchTitle);
  assert.equal(response.result.items[0].wordCount, desktopFixture.plugin.wordCount);
  assert.equal(response.result.items[0].coverUrl, null);
  assert.equal(
    response.result.items[0].latestChapter.title,
    desktopFixture.plugin.latestChapterTitle,
  );

  const discovery = await sendRequest(
    socket,
    makeRequest(ready, "c:plugin-discover", "source.discover.v1", {
      params: {
        pluginId: desktopFixture.plugin.id,
        target: null,
        cursor: null,
        collectionId: null,
        pageSize: 20,
      },
    }),
  );
  assert.equal(discovery.type, "response");
  assert.equal(discovery.result.kind, "document");
  assert.equal(discovery.result.document.components[0].type, "tabs");

  const detail = await sendRequest(
    socket,
    makeRequest(ready, "c:plugin-detail", "source.getDetail.v1", {
      params: {
        pluginId: desktopFixture.plugin.id,
        id: response.result.items[0].id,
      },
    }),
  );
  assert.equal(detail.type, "response");
  assert.equal(detail.result.catalogUrl, null);

  const chapters = await sendRequest(
    socket,
    makeRequest(ready, "c:plugin-chapters", "source.getChapters.v1", {
      params: {
        pluginId: desktopFixture.plugin.id,
        id: response.result.items[0].id,
      },
    }),
  );
  assert.equal(chapters.type, "response");
  assert.equal(chapters.result.items[0].order, 0);

  const content = await sendRequest(
    socket,
    makeRequest(ready, "c:plugin-content", "source.getContent.v1", {
      params: {
        pluginId: desktopFixture.plugin.id,
        id: response.result.items[0].id,
        chapterId: chapters.result.items[0].id,
      },
    }),
  );
  assert.equal(content.type, "response");
  assert.equal(content.result.contentKind, "novel");
  assert.deepEqual(content.result.pages, []);
});

test("source resource URLs are reusable, bounded, and forward binary responses", async (t) => {
  const runtime = await createRuntime(t, { installFixture: true });
  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(() => socket.close());
  const response = await sendRequest(socket, makeRequest(ready, "c:resource-search", "source.search.v1", {
    params: { query: "proxy-resource", cursor: null, pageSize: 1, pluginId: desktopFixture.plugin.id },
  }));
  assert.equal(response.type, "response", JSON.stringify(response));
  const resourceUrl = response.result.items[0].coverUrl;
  assert.match(resourceUrl, new RegExp(`^http://${ready.host}:${ready.port}/v1/source-resource/[A-Za-z0-9_-]{43}$`));
  for (let index = 0; index < 2; index += 1) {
    const fetched = await fetch(resourceUrl);
    assert.equal(fetched.status, 206);
    assert.equal(fetched.headers.get("content-type"), "image/test");
    assert.deepEqual([...new Uint8Array(await fetched.arrayBuffer())], [77, 71, 82, 69, 65, 68]);
  }
  assert.equal((await fetch(`${resourceUrl}x`)).status, 404);
});

test("desktop Runtime resolves the installed source directory for its Flutter Supervisor", async (t) => {
  const runtime = await createRuntime(t, { installFixture: true });
  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(() => socket.close());

  const response = await sendRequest(
    socket,
    makeRequest(ready, "c:open-source-directory", "plugins.openCodeDirectory.v1", {
      params: { pluginId: desktopFixture.plugin.id },
    }),
  );

  if (process.platform !== "win32") {
    assert.equal(response.type, "error");
    assert.equal(response.error.code, "unsupported");
    return;
  }
  assert.equal(response.type, "response");
  assert.equal(response.result.kind, "installed");
  assert.match(response.result.directory, /plugins[\\/]org\.mgread\.runtime\.fixture[\\/]versions[\\/]1\.0\.0$/);
});

test("desktop Runtime reports and clears private plugin caches without paths", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-cache-test-"));
  const installer = new PluginInstaller(dataRoot);
  await installer.installProject(fixtureRoot);
  const cacheRoot = join(dataRoot, "plugin-cache", desktopFixture.plugin.id);
  await mkdir(join(cacheRoot, "nested"), { recursive: true });
  await writeFile(join(cacheRoot, "nested", "payload.bin"), "cache-bytes");
  const runtime = new DesktopRuntime({ dataRoot });
  t.after(async () => {
    await runtime.stop();
    await rm(dataRoot, { force: true, recursive: true });
  });

  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(() => socket.close());

  const usage = await sendRequest(
    socket,
    makeRequest(ready, "c:cache-usage", "plugins.cache.usage.v1"),
  );
  assert.equal(usage.type, "response");
  assert.deepEqual(usage.result, [{ pluginId: desktopFixture.plugin.id, bytes: 11 }]);
  assert.equal(JSON.stringify(usage.result).includes(dataRoot), false);

  const archiveUsage = await sendRequest(
    socket,
    makeRequest(ready, "c:installation-archive-usage", "plugins.installation.usage.v1", {
      params: { pluginId: desktopFixture.plugin.id, scope: "archive" },
    }),
  );
  const dataUsage = await sendRequest(
    socket,
    makeRequest(ready, "c:installation-data-usage", "plugins.installation.usage.v1", {
      params: { pluginId: desktopFixture.plugin.id, scope: "data" },
    }),
  );
  const npmUsage = await sendRequest(
    socket,
    makeRequest(ready, "c:installation-npm-usage", "plugins.installation.usage.v1", {
      params: { pluginId: desktopFixture.plugin.id, scope: "npm" },
    }),
  );
  assert.equal(archiveUsage.type, "response");
  assert.equal(dataUsage.type, "response");
  assert.equal(npmUsage.type, "response");
  assert.equal(archiveUsage.result.pluginId, desktopFixture.plugin.id);
  assert.equal(archiveUsage.result.scope, "archive");
  assert.equal(dataUsage.result.pluginId, desktopFixture.plugin.id);
  assert.equal(dataUsage.result.scope, "data");
  assert.equal(npmUsage.result.scope, "npm");
  assert.ok(dataUsage.result.bytes > 0);
  assert.ok(npmUsage.result.bytes > 0);
  assert.ok(dataUsage.result.fileCount > 0);
  assert.ok(npmUsage.result.fileCount > 0);
  assert.equal(JSON.stringify(dataUsage.result).includes(dataRoot), false);
  assert.equal(JSON.stringify(npmUsage.result).includes(dataRoot), false);
  assert.equal(JSON.stringify(archiveUsage.result).includes(dataRoot), false);
  await access(join(
    dataRoot,
    "plugin-archives",
    desktopFixture.plugin.id,
    "1.0.0.mgplugin",
  ));

  const cleared = await sendRequest(
    socket,
    makeRequest(ready, "c:cache-clear", "plugins.cache.clear.v1", {
      params: { pluginId: desktopFixture.plugin.id },
    }),
  );
  assert.equal(cleared.type, "response");
  assert.deepEqual(cleared.result, {
    items: [{
      pluginId: desktopFixture.plugin.id,
      bytesBefore: 11,
      bytesRemaining: 0,
      status: "cleared",
    }],
  });
  await assert.rejects(access(join(cacheRoot, "nested", "payload.bin")));

  const allCleared = await sendRequest(
    socket,
    makeRequest(ready, "c:cache-clear-all", "plugins.cache.clearAll.v1"),
  );
  assert.equal(allCleared.type, "response");
  assert.deepEqual(allCleared.result.items, [{
    pluginId: desktopFixture.plugin.id,
    bytesBefore: 0,
    bytesRemaining: 0,
    status: "cleared",
  }]);
});

test("desktop Runtime reconciles bundled defaults per source at a cold start", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-runtime-bundled-seed-"));
  const dataRoot = join(root, "runtime-data");
  const bundledPluginRoot = join(root, "bundled-plugins");
  await mkdir(bundledPluginRoot, { recursive: true });
  await createPluginArchive(
    fixtureRoot,
    join(bundledPluginRoot, "org.mgread.runtime.fixture-1.0.0.mgplugin"),
  );
  const runtime = new DesktopRuntime({ dataRoot, bundledPluginRoot });
  t.after(async () => {
    await runtime.stop();
    await rm(root, { force: true, recursive: true });
  });

  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  t.after(() => socket.close());
  const firstList = await sendRequest(
    socket,
    makeRequest(ready, "c:bundled-seed-first", "plugins.list.v1"),
  );
  assert.equal(firstList.type, "response");
  assert.equal(firstList.result.length, 1);
  assert.equal(firstList.result[0].id, desktopFixture.plugin.id);

  socket.close();
  await runtime.stop();

  const upgradedRoot = join(root, "upgraded-fixture");
  const additionalRoot = join(root, "additional-fixture");
  await cp(fixtureRoot, upgradedRoot, { recursive: true });
  await cp(fixtureRoot, additionalRoot, { recursive: true });
  await rewriteFixturePackage(upgradedRoot, {
    id: desktopFixture.plugin.id,
    name: "@mgread-plugin/runtime-fixture",
    version: "1.0.1",
  });
  await rewriteFixturePackage(additionalRoot, {
    id: "org.mgread.runtime.extra",
    name: "@mgread-plugin/runtime-extra",
    version: "1.0.0",
  });
  await createPluginArchive(
    upgradedRoot,
    join(bundledPluginRoot, "org.mgread.runtime.fixture-1.0.1.mgplugin"),
  );
  await createPluginArchive(
    additionalRoot,
    join(bundledPluginRoot, "org.mgread.runtime.extra-1.0.0.mgplugin"),
  );

  const restarted = new DesktopRuntime({ dataRoot, bundledPluginRoot });
  t.after(() => restarted.stop());
  const restartedReady = await restarted.start();
  const restartedSocket = await openRuntimeSocket(restartedReady);
  t.after(() => restartedSocket.close());
  const secondList = await sendRequest(
    restartedSocket,
    makeRequest(restartedReady, "c:bundled-seed-second", "plugins.list.v1"),
  );
  assert.equal(secondList.type, "response");
  assert.equal(secondList.result.length, 2);
  assert.equal(
    secondList.result.find((plugin) => plugin.id === desktopFixture.plugin.id).activeVersion,
    "1.0.1",
  );
  assert.equal(
    secondList.result.find((plugin) => plugin.id === "org.mgread.runtime.extra").activeVersion,
    "1.0.0",
  );
});

test("embedded import inbox installs an archive before cold activation", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "mgread-runtime-import-inbox-"));
  const dataRoot = join(root, "runtime-data");
  const pluginImportInboxRoot = join(root, "import-inbox");
  await mkdir(pluginImportInboxRoot, { recursive: true });
  const archive = join(pluginImportInboxRoot, "runtime-fixture.mgplugin");
  await createPluginArchive(fixtureRoot, archive);
  const runtime = new DesktopRuntime({
    dataRoot,
    embedded: true,
    pluginImportInboxRoot,
  });
  t.after(async () => {
    await runtime.stop();
    await rm(root, { force: true, recursive: true });
  });

  await runtime.start();
  const listed = await runtime.invokeEmbedded("plugins.list.v1", {});
  assert.equal(listed.ok, true);
  assert.equal(listed.result.length, 1);
  assert.equal(listed.result[0].id, desktopFixture.plugin.id);
  // Android uses this same embedded DesktopRuntime behind Javet. Keep the
  // path-free size capability covered on that execution route as well as the
  // desktop WebSocket route above.
  const [archiveUsage, dataUsage, npmUsage] = await Promise.all([
    runtime.invokeEmbedded("plugins.installation.usage.v1", {
      pluginId: desktopFixture.plugin.id,
      scope: "archive",
    }),
    runtime.invokeEmbedded("plugins.installation.usage.v1", {
      pluginId: desktopFixture.plugin.id,
      scope: "data",
    }),
    runtime.invokeEmbedded("plugins.installation.usage.v1", {
      pluginId: desktopFixture.plugin.id,
      scope: "npm",
    }),
  ]);
  assert.equal(archiveUsage.ok, true);
  assert.equal(dataUsage.ok, true);
  assert.equal(npmUsage.ok, true);
  assert.equal(archiveUsage.result.pluginId, desktopFixture.plugin.id);
  assert.equal(archiveUsage.result.scope, "archive");
  assert.equal(dataUsage.result.pluginId, desktopFixture.plugin.id);
  assert.equal(dataUsage.result.scope, "data");
  assert.equal(npmUsage.result.pluginId, desktopFixture.plugin.id);
  assert.equal(npmUsage.result.scope, "npm");
  assert.ok(dataUsage.result.bytes > 0);
  assert.ok(dataUsage.result.fileCount > 0);
  assert.ok(npmUsage.result.bytes > 0);
  assert.ok(npmUsage.result.fileCount > 0);
  await assert.rejects(access(archive), (error) => error?.code === "ENOENT");
});

async function rewriteFixturePackage(root, { id, name, version }) {
  const packagePath = join(root, "package.json");
  const lockPath = join(root, "package-lock.json");
  const packageJson = JSON.parse(await readFile(packagePath, "utf8"));
  packageJson.name = name;
  packageJson.version = version;
  packageJson.mgread.id = id;
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  lock.name = name;
  lock.version = version;
  lock.packages[""] .name = name;
  lock.packages[""] .version = version;
  await writeFile(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);
  await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
}

test("desktop Runtime multiplexes bounded concurrent control requests on one socket", async (t) => {
  const runtime = await createRuntime(t);
  const ready = await runtime.start();
  const socket = await openRuntimeSocket(ready);
  const client = createMultiplexedClient(socket);
  t.after(async () => {
    client.close();
    socket.close();
    await runtime.stop();
  });

  const responses = await Promise.all(
    Array.from({ length: desktopFixture.webSocket.maxInFlightRequests }, (_, index) =>
      client.request(
        makeRequest(ready, `c:concurrent-${index}`, "runtime.ping"),
      ),
    ),
  );

  assert.equal(responses.length, desktopFixture.webSocket.maxInFlightRequests);
  for (const [index, response] of responses.entries()) {
    assert.equal(response.type, "response");
    assert.equal(response.id, `c:concurrent-${index}`);
    assert.equal(response.result.ok, true);
  }
});
