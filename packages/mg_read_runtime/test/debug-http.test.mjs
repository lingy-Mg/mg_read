/**
 * Runtime Debug inspector listener contract tests.
 *
 * Responsibilities:
 * - verify direct source projections, cover probes and transient log paging;
 * - verify fixed-port preference and temporary-port fallback;
 * - prove Debug-gated Runtime startup creates no persistent diagnostics directory.
 *
 * Boundaries:
 * - uses temporary data roots and listeners only;
 * - never relies on a running MgRead application or external network service.
 *
 * TODO:
 * - None.
 */
import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { RuntimeDebugHttpServer, RuntimeDebugLogBuffer, runtimeDebugHttpPort } from "../dist/debug-http.js";
import { DesktopRuntime } from "../dist/desktop-runtime.js";

async function startImageServer() {
  const server = createServer((_request, response) => {
    response.writeHead(200, { "Content-Length": "4", "Content-Type": "image/png" });
    response.end(Buffer.from([137, 80, 78, 71]));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.once("listening", resolve);
    server.listen({ host: "127.0.0.1", port: 0 });
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { server, url: `http://127.0.0.1:${address.port}/cover` };
}

function emptyDebugHost() {
  return {
    chapters: async () => ({ items: [] }),
    content: async () => ({ chapterId: "chapter:1", contentKind: "novel", pages: [], text: "", title: "", updatedAt: null }),
    detail: async () => ({}),
    discover: async () => ({}),
    logs: () => ({ droppedCount: 0, items: [], nextSequence: 0 }),
    plugins: async () => [],
    search: async () => ({ items: [], nextCursor: null, totalCount: 0 }),
    status: async () => ({ nodeVersion: "24.16.0", runtimeVersion: "test", status: "ready" }),
  };
}

test("Debug inspector is transient, isolates control routes, and preserves projected values", async (t) => {
  const image = await startImageServer();
  const logs = new RuntimeDebugLogBuffer();
  logs.append({
    category: "plugin.custom",
    level: "info",
    message: "request token=secret-token-123456 https://example.com/book?q=private",
    source: "plugin",
  });
  const inspector = new RuntimeDebugHttpServer({
    chapters: async () => ({ items: [{ attributes: [], id: "chapter:1", isLocked: false, order: 1, title: "第一章", updatedAt: null, url: "https://example.com/chapter/secret-token-123456", volumeTitle: null, wordCount: null }] }),
    content: async () => ({ chapterId: "chapter:1", contentKind: "novel", pages: [], text: "正文测试", title: "第一章", updatedAt: null }),
    detail: async () => ({ access: "free", aliases: ["测试别名"], attributes: [], author: "作者", catalogUrl: "https://example.com/catalog/secret-token-123456", categories: [], chapterCount: 1, contentKind: "novel", coverUrl: image.url, description: "详情", id: "novel:1", language: null, latestChapter: null, publishedAt: null, status: "ongoing", tags: [], title: "测试书", updatedAt: null, url: "https://example.com/book/secret-token-123456", wordCount: 1 }),
    discover: async () => ({
      document: {
        components: [{ children: [{ content: { attributes: [{ key: "origin", label: "来源", value: "测试数据源" }], author: "发现作者", categories: ["都市"], chapterCount: 128, coverUrl: image.url, description: "发现书简介", id: "novel:discover", latestChapter: { id: "chapter:128", title: "终章", updatedAt: "2026-08-25", url: "https://example.com/chapter/secret-token-123456" }, tags: ["推荐"], title: "发现书", url: "https://example.com/book/secret-token-123456", wordCount: 456789 }, kind: "content" }], kind: "section", title: "推荐" }],
        kind: "document",
      },
      kind: "document",
    }),
    logs: (after, limit) => logs.page(after, limit),
    plugins: async () => [],
    search: async () => ({
      items: [{ author: "作者", coverUrl: image.url + "/secret-token-123456", id: "novel:1", title: "测试书" }],
      nextCursor: null,
      totalCount: 1,
    }),
    status: async () => ({ nodeVersion: "24.16.0", runtimeVersion: "test", status: "ready" }),
  });
  t.after(async () => {
    await inspector.dispose();
    await new Promise((resolve) => image.server.close(resolve));
  });

  assert.equal(inspector.status().enabled, false);
  const enabled = await inspector.setEnabled(true);
  assert.equal(enabled.enabled, true);
  const base = enabled.endpoints.find((value) => value.startsWith("http://127.0.0.1:"));
  assert.ok(base);
  assert.equal(enabled.usingTemporaryPort, new URL(base).port !== String(runtimeDebugHttpPort));

  const page = await fetch(base);
  assert.equal(page.status, 200);
  const pageHtml = await page.text();
  assert.match(pageHtml, /<mg-debug-app/);
  assert.match(pageHtml, /__debug\/app\.js/);
  for (const route of ["/__debug/search", "/__debug/discover", "/__debug/logs"]) {
    const routedPage = await fetch(new URL(route, base));
    assert.equal(routedPage.status, 200);
    assert.match(await routedPage.text(), /<mg-debug-app/);
  }
  const pageCss = await (await fetch(new URL("/__debug/app.css", base))).text();
  assert.match(pageCss, /\.workspace-panel/);
  assert.match(pageCss, /\.tree-node/);
  const pageScript = await (await fetch(new URL("/__debug/app.js", base))).text();
  assert.match(pageScript, /customElements\.define\('mg-debug-app'/);
  assert.match(pageScript, /customElements\.define\('mg-search-panel'/);
  assert.match(pageScript, /customElements\.define\('mg-discovery-panel'/);
  assert.match(pageScript, /customElements\.define\('mg-log-viewer'/);
  assert.match(pageScript, /createDiscoveryNode/);
  assert.equal((await fetch(new URL("/v1/rpc", base))).status, 404);

  const liveLogs = await (await fetch(new URL("/__debug/api/logs?after=0&limit=20", base))).json();
  assert.equal(liveLogs.items.length, 1);
  assert.equal(liveLogs.items[0].category, "plugin.custom");
  assert.equal(liveLogs.items[0].message, "request token=secret-token-123456 https://example.com/book?q=private");

  const search = await fetch(new URL("/__debug/api/search?pluginId=org.example.test&q=test&pageSize=1", base));
  assert.equal(search.status, 200);
  const result = await search.json();
  const cover = result.result.items[0].cover;
  assert.equal(cover.type, "ordinary-url");
  assert.equal(cover.displayUrl, image.url + "/secret-token-123456");

  const discover = await fetch(new URL("/__debug/api/discover?pluginId=org.example.test&pageSize=1", base));
  assert.equal(discover.status, 200);
  const discoveryResult = await discover.json();
  assert.equal(discoveryResult.result.document.components[0].kind, "section");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.cover.type, "ordinary-url");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.chapterCount, 128);
  assert.equal(discoveryResult.result.document.components[0].children[0].content.attributes[0].label, "来源");
  assert.equal(discoveryResult.result.document.components[0].children[0].content.url, "https://example.com/book/secret-token-123456");

  const detail = await (await fetch(new URL("/__debug/api/detail?pluginId=org.example.test&id=novel%3A1", base))).json();
  assert.equal(detail.result.aliases[0], "测试别名");
  assert.equal(detail.result.catalogUrl, "https://example.com/catalog/secret-token-123456");
  const chapters = await (await fetch(new URL("/__debug/api/chapters?pluginId=org.example.test&id=novel%3A1", base))).json();
  assert.equal(chapters.result.items[0].title, "第一章");
  assert.equal(chapters.result.items[0].url, "https://example.com/chapter/secret-token-123456");
  const content = await (await fetch(new URL("/__debug/api/content?pluginId=org.example.test&id=novel%3A1&chapterId=chapter%3A1", base))).json();
  assert.equal(content.result.text, "正文测试");

  const probe = await fetch(new URL(`/__debug/api/resource-probe?probeId=${cover.probeId}`, base));
  assert.equal(probe.status, 200);
  assert.equal(probe.headers.get("content-type"), "image/png");
  assert.deepEqual([...new Uint8Array(await probe.arrayBuffer())], [137, 80, 78, 71]);

  const disabled = await inspector.setEnabled(false);
  assert.deepEqual(disabled, { configuredEnabled: false, enabled: false, endpoints: [], startedAt: null, usingTemporaryPort: false });
});

test("Debug inspector uses a temporary port when the preferred port is occupied", async (t) => {
  const blocker = createServer();
  await new Promise((resolve, reject) => {
    blocker.once("error", reject);
    blocker.once("listening", resolve);
    blocker.listen({ host: "0.0.0.0", port: 0 });
  });
  const blockedAddress = blocker.address();
  assert.ok(blockedAddress && typeof blockedAddress !== "string");
  const inspector = new RuntimeDebugHttpServer(emptyDebugHost(), blockedAddress.port);
  t.after(async () => {
    await inspector.dispose();
    await new Promise((resolve) => blocker.close(resolve));
  });

  const enabled = await inspector.setEnabled(true);
  const loopbackEndpoint = enabled.endpoints.find((value) => value.startsWith("http://127.0.0.1:"));
  assert.equal(enabled.configuredEnabled, true);
  assert.equal(enabled.enabled, true);
  assert.equal(enabled.usingTemporaryPort, true);
  assert.ok(loopbackEndpoint);
  assert.notEqual(new URL(loopbackEndpoint).port, String(blockedAddress.port));
  assert.deepEqual(inspector.status(), enabled);
});

test("Runtime persists the Debug preference and restores the fixed listener", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-debug-preference-"));
  let runtime = new DesktopRuntime({ dataRoot, debugHttpAllowed: true });
  t.after(async () => {
    await runtime.stop();
    await rm(dataRoot, { force: true, recursive: true });
  });

  await runtime.start();
  const enabled = await runtime.invokeEmbedded("runtime.debugHttp.setEnabled.v1", { enabled: true });
  assert.equal(enabled.ok, true);
  assert.equal(enabled.result.configuredEnabled, true);
  assert.equal(enabled.result.enabled, true);
  const enabledEndpoint = new URL(enabled.result.endpoints[0]);
  assert.equal(enabled.result.usingTemporaryPort, enabledEndpoint.port !== String(runtimeDebugHttpPort));
  assert.deepEqual(
    JSON.parse(await readFile(join(dataRoot, "runtime-settings", "debug-http.json"), "utf8")),
    { enabled: true },
  );

  await runtime.stop();
  runtime = new DesktopRuntime({ dataRoot, debugHttpAllowed: true });
  await runtime.start();
  const restored = await runtime.invokeEmbedded("runtime.debugHttp.status.v1", {});
  assert.equal(restored.ok, true);
  assert.equal(restored.result.configuredEnabled, true);
  assert.equal(restored.result.enabled, true);
  const restoredEndpoint = new URL(restored.result.endpoints[0]);
  assert.equal(restored.result.usingTemporaryPort, restoredEndpoint.port !== String(runtimeDebugHttpPort));
  await assert.rejects(access(join(dataRoot, "diagnostics")), (error) => error?.code === "ENOENT");
});

test("Runtime rejects Debug listener control without the platform Debug build gate", async (t) => {
  const dataRoot = await mkdtemp(join(tmpdir(), "mgread-no-runtime-events-"));
  const runtime = new DesktopRuntime({ dataRoot });
  t.after(async () => {
    await runtime.stop();
    await rm(dataRoot, { force: true, recursive: true });
  });
  await runtime.start();

  const result = await runtime.invokeEmbedded("runtime.debugHttp.setEnabled.v1", { enabled: true });
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "method_not_found");
  await assert.rejects(access(join(dataRoot, "diagnostics")), (error) => error?.code === "ENOENT");
});

test("Debug log buffer retains every listener-lifetime entry, is pageable, and clearable", () => {
  const logs = new RuntimeDebugLogBuffer();
  for (let index = 1; index <= 1_005; index += 1) {
    logs.append({
      category: "runtime.diagnostic",
      level: "info",
      message: `entry ${index} password=private`,
      source: "runtime",
    });
  }

  const first = logs.page(0, 200);
  const second = logs.page(first.nextSequence, 200);
  assert.equal(first.items.length, 200);
  assert.equal(first.items[0].sequence, 1);
  assert.equal(first.items.at(-1).sequence, 200);
  assert.equal(second.items[0].sequence, 201);
  assert.equal(second.items.at(-1).sequence, 400);
  assert.equal(first.latestSequence, 1_005);
  assert.equal(first.items[0].category, "runtime.diagnostic");
  assert.equal(first.items[0].message, "entry 1 password=private");

  logs.clear();
  assert.deepEqual(logs.page(0, 200), { items: [], latestSequence: 1_005, nextSequence: 1_005 });
});
