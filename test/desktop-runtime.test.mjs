import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  DesktopRuntime,
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

async function createRuntime(t, { installFixture = false } = {}) {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-runtime-node-test-"));
  if (installFixture) {
    const installer = new PluginInstaller(dataRoot);
    await installer.installProject(
      fileURLToPath(new URL("./fixtures/standard-plugin/", import.meta.url)),
    );
  }
  const runtime = new DesktopRuntime({ dataRoot });
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
        pageSize: 20,
      },
    }),
  );
  assert.equal(discovery.type, "response");
  assert.equal(discovery.result.sections[0].layout, "featured");

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
        cursor: null,
        pageSize: 20,
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
